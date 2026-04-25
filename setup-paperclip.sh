#!/usr/bin/env bash
# ============================================================================
#  Paperclip self-hosting + agent-client bootstrap
# ----------------------------------------------------------------------------
#  What this does, in order:
#    1. Creates the `paperclip` system user (idempotent).
#    2. Installs system packages (curl, git, build-essential, nginx…).
#    2.5 Installs GitHub CLI (gh) from the official cli.github.com apt repo.
#    3. Installs Node.js 24 + pnpm (Paperclip needs Node 20+; Paperclip's own
#       Dockerfile now uses Node 24, so we match that).
#    4. (Firewall is no longer configured here — see harden-server.sh.)
#    5. Sets a per-user npm prefix for `paperclip` so `npm -g` works without
#       sudo (Anthropic explicitly recommends against `sudo npm install -g`).
#    6. Clones github.com/paperclipai/paperclip and runs pnpm install + build.
#    7. Installs four agent clients into the paperclip user's home:
#         - Hermes Agent          (~/.hermes/bin/hermes)
#         - Claude Code           (~/.claude/bin/claude)
#         - OpenAI Codex CLI      (~/.npm-global/bin/codex)
#         - opencode              (~/.opencode/bin/opencode  or  ~/.local/bin)
#    8. Installs hermes-paperclip-adapter into Paperclip's server workspace
#       and registers the `hermes_local` adapter type in
#       server/src/adapters/registry.ts via an idempotent overlay tool
#       (paperclip/.paperclip-local/). Companion script update-paperclip.sh
#       safely re-applies the overlay after every `git pull`.
#    9. (Optional) Writes an nginx reverse-proxy site for port 3100.
#    9.5 (Optional, SETUP_WIREGUARD=1) Installs a WireGuard server on
#       wg0 with a generated keypair and provides /usr/local/sbin/add-wg-peer
#       to mint client configs (with QR code). Reach Paperclip from a peer
#       at http://<wg-server-ip>/ once the tunnel is up.
#   10. (Optional) Writes a systemd unit so Paperclip restarts on boot.
#
#  Notes / honest caveats:
#    - The page at papercliphosting.ai/guides/paperclip-self-hosting-guide is a
#      third-party affiliate site. Its repo URL and run command are wrong.
#      This script follows the actual upstream (paperclipai/paperclip).
#    - For a real production deployment, Paperclip's own `docker/` setup is a
#      better long-term path than `pnpm dev:once`. Adapt as you see fit.
#    - The hermes-paperclip-adapter requires a one-line registration in
#      Paperclip's source tree. We do that automatically with an idempotent
#      overlay (see paperclip/.paperclip-local/) so `git pull` doesn't break
#      it. If the adapter README ever changes the public registration shape,
#      the overlay tool will refuse to patch and tell you.
#    - You still have to authenticate each client once interactively
#      (`hermes`, `claude`, `codex`, `opencode`) as the paperclip user.
#
#  Tested target: Ubuntu 22.04 / 24.04, Debian 12.   Run as root (or sudo).
# ============================================================================

set -euo pipefail

# ---------- configurable knobs (override via env) ---------------------------
PAPERCLIP_USER="${PAPERCLIP_USER:-paperclip}"
PAPERCLIP_HOME="/home/${PAPERCLIP_USER}"
PAPERCLIP_PORT="${PAPERCLIP_PORT:-3100}"
PAPERCLIP_DOMAIN="${PAPERCLIP_DOMAIN:-_}"   # `_` = catch-all server_name
PAPERCLIP_REPO="${PAPERCLIP_REPO:-https://github.com/paperclipai/paperclip.git}"
HERMES_ADAPTER_PKG="${HERMES_ADAPTER_PKG:-hermes-paperclip-adapter}"
NODE_MAJOR="${NODE_MAJOR:-24}"
GRANT_SUDO="${GRANT_SUDO:-0}"               # 1 = add paperclip to sudo group
SUDO_NOPASSWD="${SUDO_NOPASSWD:-0}"         # 1 = drop a NOPASSWD sudoers rule
                                            #     for the paperclip user.
                                            # Only honoured when GRANT_SUDO=1.
                                            # When 0 *and* the user has no
                                            # password, the user will be in
                                            # the sudo group but unable to use
                                            # sudo — the script warns about
                                            # this.
SETUP_NGINX="${SETUP_NGINX:-1}"             # 0 = skip nginx site
SETUP_SYSTEMD="${SETUP_SYSTEMD:-1}"         # 0 = skip systemd unit
SETUP_WIREGUARD="${SETUP_WIREGUARD:-0}"     # 1 = install WireGuard server
WIREGUARD_PORT="${WIREGUARD_PORT:-51820}"   # UDP listen port
WIREGUARD_NET="${WIREGUARD_NET:-10.7.0.0/24}"
WIREGUARD_SERVER_IP="${WIREGUARD_SERVER_IP:-10.7.0.1}"
PAPERCLIP_START_CMD="${PAPERCLIP_START_CMD:-pnpm dev:once}"
# ---------------------------------------------------------------------------

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
# ANSI-C quoting puts real ESC bytes into the variables, so they can be
# interpolated into heredocs (which don't expand \033 escapes themselves).
C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RESET=$'\033[0m'

# ---------- 0. preflight ----------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root (or with sudo)."
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "This script targets Ubuntu/Debian; got '${ID:-unknown}'." ;;
esac

# Run a command as the paperclip user with a real login shell so PATH/.bashrc
# get sourced.
as_paperclip() {
  sudo -u "$PAPERCLIP_USER" -H bash -lc "$1"
}

# ---------- 1. user ---------------------------------------------------------
log "Ensuring user '${PAPERCLIP_USER}' exists with a real home"
if ! id "$PAPERCLIP_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" --home "$PAPERCLIP_HOME" "$PAPERCLIP_USER"
fi

# Repair an existing user whose home is missing or set to /nonexistent
# (happens when the account was previously created via `useradd -r` or
# similar). Without this, every `as_paperclip` call below tries to write
# into /nonexistent and fails.
cur_home="$(getent passwd "$PAPERCLIP_USER" | cut -d: -f6)"
if [[ "$cur_home" != "$PAPERCLIP_HOME" || ! -d "$cur_home" ]]; then
  log "Repairing home for '${PAPERCLIP_USER}' (was: '${cur_home:-<unset>}' -> '${PAPERCLIP_HOME}')"
  usermod -d "$PAPERCLIP_HOME" "$PAPERCLIP_USER"
  install -d -m 0755 -o "$PAPERCLIP_USER" -g "$PAPERCLIP_USER" "$PAPERCLIP_HOME"
  for skel in .bashrc .profile .bash_logout; do
    if [[ -f "/etc/skel/$skel" && ! -e "$PAPERCLIP_HOME/$skel" ]]; then
      cp "/etc/skel/$skel" "$PAPERCLIP_HOME/$skel"
      chown "$PAPERCLIP_USER:$PAPERCLIP_USER" "$PAPERCLIP_HOME/$skel"
    fi
  done
fi

if [[ "$GRANT_SUDO" == "1" ]]; then
  usermod -aG sudo "$PAPERCLIP_USER"
  # adduser --disabled-password leaves the account with no usable password.
  # Membership in `sudo` alone does NOT give them working sudo in that case
  # — sudo will prompt for a password they can't provide. Resolve this
  # explicitly: either drop a NOPASSWD rule (SUDO_NOPASSWD=1) or warn the
  # operator that they need to set a password before sudo will work.
  has_password=0
  if passwd -S "$PAPERCLIP_USER" 2>/dev/null | awk '{print $2}' | grep -qx 'P'; then
    has_password=1
  fi

  if [[ "$SUDO_NOPASSWD" == "1" ]]; then
    log "Writing /etc/sudoers.d/${PAPERCLIP_USER} (NOPASSWD)"
    sudoers_file="/etc/sudoers.d/${PAPERCLIP_USER}"
    cat > "${sudoers_file}.tmp" <<SUDOEOF
# Managed by setup-paperclip.sh — passwordless sudo for the service user.
${PAPERCLIP_USER} ALL=(ALL) NOPASSWD:ALL
SUDOEOF
    chmod 0440 "${sudoers_file}.tmp"
    # Validate before swapping in — a broken sudoers file can lock everyone
    # out of sudo for good. visudo -c rejects bad syntax with non-zero exit.
    if visudo -cf "${sudoers_file}.tmp" >/dev/null; then
      mv "${sudoers_file}.tmp" "${sudoers_file}"
      warn "Granted '${PAPERCLIP_USER}' PASSWORDLESS sudo (GRANT_SUDO=1, SUDO_NOPASSWD=1)."
    else
      rm -f "${sudoers_file}.tmp"
      die "visudo rejected the generated sudoers file — refusing to install it"
    fi
  elif [[ "$has_password" == "1" ]]; then
    warn "Granted '${PAPERCLIP_USER}' sudo (password required at each call)."
  else
    warn "Granted '${PAPERCLIP_USER}' sudo group membership — but the account has NO password,"
    warn "so sudo will REJECT every call until you either:"
    warn "  - set a password:   sudo passwd ${PAPERCLIP_USER}"
    warn "  - or re-run setup with SUDO_NOPASSWD=1 (passwordless sudo)"
  fi
fi

# ---------- 2. system packages ---------------------------------------------
log "Updating apt + installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get -y install \
  curl ca-certificates gnupg git build-essential unzip wget \
  ripgrep silversearcher-ag \
  nano less htop \
  python3 python3-pip python3-venv \
  nginx

# ---------- 2.5 GitHub CLI (gh) -------------------------------------------
# Official install path from https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian
# Idempotent: re-fetches the keyring (cheap, single file) and only writes
# the apt source if missing.
log "Installing GitHub CLI (gh) from cli.github.com apt repo"
install -d -m 0755 /etc/apt/keyrings
GH_KEYRING=/etc/apt/keyrings/githubcli-archive-keyring.gpg
wget -nv -O "$GH_KEYRING" https://cli.github.com/packages/githubcli-archive-keyring.gpg
chmod go+r "$GH_KEYRING"
GH_LIST=/etc/apt/sources.list.d/github-cli.list
GH_LINE="deb [arch=$(dpkg --print-architecture) signed-by=${GH_KEYRING}] https://cli.github.com/packages stable main"
if [[ ! -f "$GH_LIST" ]] || ! grep -qxF "$GH_LINE" "$GH_LIST"; then
  printf '%s\n' "$GH_LINE" > "$GH_LIST"
fi
apt-get update -y
apt-get -y install gh

# ---------- 3. Node.js + pnpm ----------------------------------------------
need_node=1
if command -v node >/dev/null 2>&1; then
  cur="$(node -v | sed 's/^v\([0-9]\+\).*/\1/')"
  [[ "$cur" -ge "$NODE_MAJOR" ]] && need_node=0
fi
if [[ "$need_node" == "1" ]]; then
  log "Installing Node.js ${NODE_MAJOR}.x via NodeSource"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get -y install nodejs
else
  log "Node.js $(node -v) already meets the minimum (>= ${NODE_MAJOR})"
fi

# Paperclip wants pnpm >= 9.15. Skip the install if a satisfying pnpm is
# already on PATH — re-running `npm i -g` over an existing binary fails
# with EEXIST. Use --force on actual upgrades to overwrite the old file.
PNPM_MIN="9.15.0"
need_pnpm=1
if command -v pnpm >/dev/null 2>&1; then
  cur_pnpm="$(pnpm -v 2>/dev/null || true)"
  if [[ -n "$cur_pnpm" ]] \
     && printf '%s\n%s\n' "$PNPM_MIN" "$cur_pnpm" | sort -V -C 2>/dev/null; then
    need_pnpm=0
  fi
fi
if [[ "$need_pnpm" == "1" ]]; then
  log "Installing pnpm globally (>= ${PNPM_MIN})"
  npm install -g --force "pnpm@>=${PNPM_MIN%.*}"
else
  log "pnpm $(pnpm -v) already meets the minimum (>= ${PNPM_MIN})"
fi
node -v; npm -v; pnpm -v

# ---------- 4. (firewall moved to harden-server.sh) ------------------------
# UFW is configured by the dedicated hardening script. This keeps the network
# policy in one place with the rest of the security baseline.

# ---------- 5. paperclip user shell + per-user npm prefix ------------------
# Centralise the PATH export in ~/.paperclip-env and source it from BOTH
# .bashrc (for interactive shells) AND .profile (for login + non-interactive
# `bash -lc`, which is what every `as_paperclip` call here uses). Debian's
# stock .bashrc returns early on non-interactive shells, so PATH set there
# alone wouldn't survive `bash -lc` and the agent binaries we just installed
# would look "missing" right after install.
log "Configuring shell + per-user npm prefix for ${PAPERCLIP_USER}"
as_paperclip '
set -e
mkdir -p "$HOME/.npm-global" "$HOME/.local/bin"
npm config set prefix "$HOME/.npm-global"

cat > "$HOME/.paperclip-env" << "EOF"
# Managed by setup-paperclip.sh — sourced from .bashrc and .profile.

# Drop duplicate entries from $PATH while preserving the first occurrence.
# Safe to call multiple times. Also exposed as a command for manual cleanup.
dedupe_path() {
  PATH="$(printf %s "$PATH" | awk -v RS=: -v ORS=: '\''$0 != "" && !seen[$0]++'\'' | sed '\''s/:$//'\'')"
  export PATH
}

export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.hermes/bin:$HOME/.claude/bin:$HOME/.opencode/bin:$PATH"
dedupe_path
EOF

for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  touch "$rc"
  if ! grep -q "PAPERCLIP_PATHS" "$rc"; then
    cat >> "$rc" << "EOF"

# --- PAPERCLIP_PATHS -------------------------------------------------------
[ -f "$HOME/.paperclip-env" ] && . "$HOME/.paperclip-env"
# --- /PAPERCLIP_PATHS ------------------------------------------------------
EOF
  fi
done
'

# ---------- 6. clone + build Paperclip -------------------------------------
log "Cloning + building Paperclip in ${PAPERCLIP_HOME}/paperclip"
as_paperclip "
set -e
cd \"\$HOME\"
if [ ! -d paperclip/.git ]; then
  git clone --depth=1 '${PAPERCLIP_REPO}' paperclip
else
  cd paperclip && git pull --ff-only
fi
"
as_paperclip '
set -e
cd "$HOME/paperclip"
pnpm install --frozen-lockfile || pnpm install
pnpm build
'

if [[ ! -f "${PAPERCLIP_HOME}/paperclip/.env" && -f "${PAPERCLIP_HOME}/paperclip/.env.example" ]]; then
  log "Seeding .env from .env.example (review before going to production)"
  as_paperclip '[ -e "$HOME/paperclip/.env" ] || cp "$HOME/paperclip/.env.example" "$HOME/paperclip/.env"'
fi

# ---------- 7. agent clients (all installed for paperclip user) ------------
log "Installing Hermes Agent (Nous Research)"
as_paperclip 'curl -fsSL https://hermes.nousresearch.com/install.sh | bash' \
  || warn "Hermes installer failed — re-run manually as ${PAPERCLIP_USER}."

log "Installing Claude Code (native installer, Anthropic)"
as_paperclip 'curl -fsSL https://claude.ai/install.sh | bash' \
  || warn "Claude Code installer failed — re-run manually as ${PAPERCLIP_USER}."

log "Installing OpenAI Codex CLI"
as_paperclip 'npm install -g @openai/codex' \
  || warn "Codex CLI install failed — re-run manually as ${PAPERCLIP_USER}."

log "Installing opencode (sst/opencode)"
as_paperclip 'curl -fsSL https://opencode.ai/install | bash' \
  || warn "opencode installer failed — re-run manually as ${PAPERCLIP_USER}."

# Quick sanity check (won't fail the script if a binary is missing)
log "Detected agent binaries:"
as_paperclip '
for b in hermes claude codex opencode; do
  if command -v "$b" >/dev/null 2>&1; then
    printf "  %-9s -> %s\n" "$b" "$(command -v "$b")"
  else
    printf "  %-9s -> NOT FOUND on PATH (login as %s and re-run installer)\n" "$b" "'"$PAPERCLIP_USER"'"
  fi
done
' || true

# ---------- 7.5 hermes-paperclip-adapter (registers hermes_local) ----------
log "Writing idempotent overlay tool to paperclip/.paperclip-local/"
install -d -o "$PAPERCLIP_USER" -g "$PAPERCLIP_USER" \
  "${PAPERCLIP_HOME}/paperclip/.paperclip-local"

# patch-registry.py — idempotent, sentinel-driven patcher for
# server/src/adapters/registry.ts. Re-running it is a no-op once the
# sentinels are in place. If it can't find the expected anchors (e.g.
# upstream restructured the registry), it leaves the file untouched and
# exits non-zero with a clear message — never silently corrupts.
cat > "${PAPERCLIP_HOME}/paperclip/.paperclip-local/patch-registry.py" <<'PYEOF'
#!/usr/bin/env python3
"""Register hermes_local in server/src/adapters/registry.ts (idempotent)."""
import os, re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
REG  = ROOT / "server" / "src" / "adapters" / "registry.ts"

IMPORT_SENTINEL = "// __HERMES_LOCAL_IMPORTS__"
REG_SENTINEL    = "// __HERMES_LOCAL_REGISTRATION__"

IMPORT_BLOCK = f"""\
{IMPORT_SENTINEL}
import * as hermesLocal from "hermes-paperclip-adapter";
import {{
  execute as hermesExecute,
  testEnvironment as hermesTestEnvironment,
  detectModel as hermesDetectModel,
  listSkills as hermesListSkills,
  syncSkills as hermesSyncSkills,
  sessionCodec as hermesSessionCodec,
}} from "hermes-paperclip-adapter/server";
// __END_HERMES_LOCAL_IMPORTS__
"""

REG_BLOCK = f"""\

{REG_SENTINEL}
// Registers Hermes Agent (https://github.com/paperclipai/hermes-paperclip-adapter)
// as the `hermes_local` adapter. Re-applied automatically by
// .paperclip-local/apply-overlays.sh after every git pull.
try {{
  registry.set("hermes_local", {{
    ...hermesLocal,
    execute: hermesExecute,
    testEnvironment: hermesTestEnvironment,
    detectModel: hermesDetectModel,
    listSkills: hermesListSkills,
    syncSkills: hermesSyncSkills,
    sessionCodec: hermesSessionCodec,
  }});
}} catch (err) {{
  // Surface clearly without crashing the server: registry shape may have
  // changed upstream — in that case, run .paperclip-local/apply-overlays.sh
  // which will refuse to patch and print guidance.
  // eslint-disable-next-line no-console
  console.error("[hermes_local overlay] registration failed:", err);
}}
// __END_HERMES_LOCAL_REGISTRATION__
"""

def die(msg, code=1):
    print(f"[patch-registry] ERROR: {msg}", file=sys.stderr); sys.exit(code)

def main():
    if not REG.exists():
        die(f"{REG} not found — has the upstream layout changed?")

    src = REG.read_text(encoding="utf-8")
    have_imports = IMPORT_SENTINEL in src
    have_reg     = REG_SENTINEL in src

    if have_imports and have_reg:
        print("[patch-registry] already applied — nothing to do.")
        return 0

    # --- Sanity check that the file looks like a registry ---------------
    # We expect either a `registry.set(` call, or a `Map<...>` named
    # `registry`/`adapterRegistry`. If we see neither, we abort.
    if not (re.search(r"\bregistry\s*\.\s*set\s*\(", src)
            or re.search(r"\b(registry|adapterRegistry)\s*[:=]\s*new\s+Map", src)):
        die("registry.ts does not look like a Map-based registry "
            "(no `registry.set(` or `new Map`). Refusing to patch. "
            "Apply the snippet from "
            "https://github.com/paperclipai/hermes-paperclip-adapter manually.")

    new_src = src

    # --- Insert imports right after the last top-of-file `import ...` ---
    if not have_imports:
        # Find the last contiguous import block at the top of the file.
        lines = new_src.splitlines(keepends=True)
        last_import_idx = -1
        for i, line in enumerate(lines):
            stripped = line.lstrip()
            if stripped.startswith("import ") or stripped.startswith("from "):
                last_import_idx = i
            elif last_import_idx >= 0 and stripped == "":
                # blank line right after imports — keep scanning, multi-line
                # imports may resume
                continue
            elif last_import_idx >= 0:
                break
        if last_import_idx < 0:
            die("could not find any `import` statement at the top of registry.ts")
        insert_at = last_import_idx + 1
        lines.insert(insert_at, "\n" + IMPORT_BLOCK)
        new_src = "".join(lines)

    # --- Append registration at the very end of the file ----------------
    if not have_reg:
        if not new_src.endswith("\n"):
            new_src += "\n"
        new_src += REG_BLOCK

    REG.write_text(new_src, encoding="utf-8")
    print(f"[patch-registry] patched {REG.relative_to(ROOT)}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
PYEOF

# apply-overlays.sh — installs the npm package (if missing) and runs the
# patcher. Designed to be safe to re-run any number of times.
cat > "${PAPERCLIP_HOME}/paperclip/.paperclip-local/apply-overlays.sh" <<'SHEOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. Make sure hermes-paperclip-adapter is in the server workspace.
if [ -d server ] && [ -f server/package.json ]; then
  if ! grep -q '"hermes-paperclip-adapter"' server/package.json; then
    echo "[overlays] adding hermes-paperclip-adapter to server workspace"
    pnpm --filter ./server add hermes-paperclip-adapter
  else
    echo "[overlays] hermes-paperclip-adapter already in server/package.json"
  fi
else
  echo "[overlays] server/package.json not found — skipping pnpm add" >&2
fi

# 2. Apply the registry patch (idempotent).
python3 .paperclip-local/patch-registry.py
SHEOF
chmod +x "${PAPERCLIP_HOME}/paperclip/.paperclip-local/patch-registry.py" \
         "${PAPERCLIP_HOME}/paperclip/.paperclip-local/apply-overlays.sh"
chown -R "$PAPERCLIP_USER":"$PAPERCLIP_USER" \
  "${PAPERCLIP_HOME}/paperclip/.paperclip-local"

log "Registering hermes_local adapter + rebuilding"
as_paperclip '
set -e
cd "$HOME/paperclip"
./.paperclip-local/apply-overlays.sh
pnpm install
pnpm build
' || warn "Overlay/build step had a problem — check the output above. " \
        "If patch-registry.py refused to patch, register hermes_local " \
        "manually per the adapter README."

# ---------- 8. nginx reverse proxy (optional) ------------------------------
if [[ "$SETUP_NGINX" == "1" ]]; then
  log "Writing nginx site for paperclip (port ${PAPERCLIP_PORT})"
  cat > /etc/nginx/sites-available/paperclip <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${PAPERCLIP_DOMAIN};

    # Paperclip uses WebSockets — Upgrade/Connection headers are required.
    location / {
        proxy_pass         http://127.0.0.1:${PAPERCLIP_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
NGINX
  ln -sf /etc/nginx/sites-available/paperclip /etc/nginx/sites-enabled/paperclip
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl reload nginx || systemctl restart nginx
fi

# ---------- 8.5 WireGuard server (optional) --------------------------------
# When SETUP_WIREGUARD=1, install WireGuard and set up a server interface
# (wg0) that you can later add peers to via add-wg-peer. Reaching the
# Paperclip UI from a peer is then just a matter of pointing the browser at
# http://${WIREGUARD_SERVER_IP}/ once the tunnel is up — nginx already
# listens on every interface, and harden-server.sh detects wg0 and opens
# the right firewall rules automatically.
if [[ "$SETUP_WIREGUARD" == "1" ]]; then
  log "Installing WireGuard"
  apt-get -y install wireguard wireguard-tools qrencode

  install -d -m 0700 /etc/wireguard
  if [[ ! -s /etc/wireguard/server_private.key ]]; then
    log "Generating WireGuard server keypair"
    umask 077
    wg genkey | tee /etc/wireguard/server_private.key \
              | wg pubkey > /etc/wireguard/server_public.key
    chmod 600 /etc/wireguard/server_private.key
    chmod 644 /etc/wireguard/server_public.key
  fi

  if [[ ! -f /etc/wireguard/wg0.conf ]]; then
    log "Writing /etc/wireguard/wg0.conf"
    SERVER_PRIV="$(cat /etc/wireguard/server_private.key)"
    cat > /etc/wireguard/wg0.conf <<WGEOF
# Managed by setup-paperclip.sh. Peers are appended by /usr/local/sbin/add-wg-peer.
# Don't enable SaveConfig — wg-quick would rewrite this file and we'd lose the
# header / formatting. add-wg-peer keeps things in sync via \`wg syncconf\`.
[Interface]
Address    = ${WIREGUARD_SERVER_IP}/${WIREGUARD_NET#*/}
ListenPort = ${WIREGUARD_PORT}
PrivateKey = ${SERVER_PRIV}
WGEOF
    chmod 600 /etc/wireguard/wg0.conf
  fi

  log "Writing /usr/local/sbin/add-wg-peer helper"
  cat > /usr/local/sbin/add-wg-peer <<'PEEREOF'
#!/usr/bin/env bash
# add-wg-peer <name> [--full-tunnel]
#   Generates a WireGuard client keypair + preshared key, allocates the
#   next free IP in the configured subnet, appends a [Peer] block to
#   /etc/wireguard/wg0.conf, applies it live with `wg syncconf`, and
#   writes the client config to /etc/wireguard/clients/<name>.conf.
#   Prints the client config and a QR code (if qrencode is installed)
#   ready to scan from the WireGuard mobile app.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

NAME="${1:-}"
FULL_TUNNEL=0
shift || true
for a in "$@"; do
  case "$a" in
    --full-tunnel) FULL_TUNNEL=1 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done
[[ -n "$NAME" ]] || { echo "usage: $0 <name> [--full-tunnel]" >&2; exit 2; }
[[ "$NAME" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "name must be [a-zA-Z0-9._-]+" >&2; exit 2; }

CONF=/etc/wireguard/wg0.conf
[[ -f "$CONF" ]] || { echo "$CONF not found — was setup-paperclip.sh run with SETUP_WIREGUARD=1?" >&2; exit 1; }

CLIENT_DIR=/etc/wireguard/clients
install -d -m 0700 "$CLIENT_DIR"
OUT="$CLIENT_DIR/$NAME.conf"
[[ ! -e "$OUT" ]] || { echo "$OUT already exists — pick a different name or delete it first" >&2; exit 1; }

# --- Parse server settings from wg0.conf ----------------------------------
SERVER_ADDR="$(awk -F'= *' '/^Address/    {print $2; exit}' "$CONF")"
SERVER_PORT="$(awk -F'= *' '/^ListenPort/ {print $2; exit}' "$CONF")"
SERVER_NET="${SERVER_ADDR%/*}"               # e.g. 10.7.0.1
SERVER_PREFIX="${SERVER_ADDR#*/}"            # e.g. 24
NET_BASE="${SERVER_NET%.*}"                  # e.g. 10.7.0
SERVER_PUB="$(cat /etc/wireguard/server_public.key)"

# --- Pick the lowest free IP in the subnet --------------------------------
# Use awk (not grep) for the first stage: awk returns 0 even with no match,
# so an empty wg0.conf (no peers yet) doesn't trip set -o pipefail and kill
# the script silently before we ever append the first peer.
USED="$(awk -F'= *' '/^AllowedIPs/ {print $2}' "$CONF" \
        | tr ',' '\n' | sed 's|/.*||' | awk -F. '{print $NF}' | sort -nu)"
USED+=$'\n'"${SERVER_NET##*.}"   # exclude the server itself
NEXT=""
for i in $(seq 2 254); do
  if ! grep -qx "$i" <<<"$USED"; then NEXT="$i"; break; fi
done
[[ -n "$NEXT" ]] || { echo "subnet exhausted" >&2; exit 1; }
PEER_IP="${NET_BASE}.${NEXT}"

# --- Resolve a sensible Endpoint host -------------------------------------
ENDPOINT_HOST="$(curl -fsS https://api.ipify.org 2>/dev/null \
              || hostname -I | awk '{print $1}')"

# --- Generate client keypair + PSK ----------------------------------------
umask 077
CLIENT_PRIV="$(wg genkey)"
CLIENT_PUB="$(printf '%s' "$CLIENT_PRIV" | wg pubkey)"
PSK="$(wg genpsk)"

# --- Append [Peer] block to server config ---------------------------------
cat >> "$CONF" <<EOF

# peer: $NAME
[Peer]
PublicKey    = $CLIENT_PUB
PresharedKey = $PSK
AllowedIPs   = ${PEER_IP}/32
EOF

# --- Apply live without dropping the interface ----------------------------
if wg show wg0 >/dev/null 2>&1; then
  wg syncconf wg0 <(wg-quick strip wg0)
fi

# --- Build + emit client config -------------------------------------------
if [[ "$FULL_TUNNEL" == "1" ]]; then
  ALLOWED="0.0.0.0/0, ::/0"
else
  ALLOWED="${NET_BASE}.0/${SERVER_PREFIX}"
fi

cat > "$OUT" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address    = ${PEER_IP}/32
DNS        = 1.1.1.1, 9.9.9.9

[Peer]
PublicKey    = $SERVER_PUB
PresharedKey = $PSK
Endpoint     = ${ENDPOINT_HOST}:${SERVER_PORT}
AllowedIPs   = ${ALLOWED}
PersistentKeepalive = 25
EOF
chmod 600 "$OUT"

echo
echo "=== client config saved to $OUT ==="
cat "$OUT"
if command -v qrencode >/dev/null 2>&1; then
  echo
  echo "=== QR (scan with the WireGuard mobile app) ==="
  qrencode -t ansiutf8 < "$OUT"
fi
echo
echo "Reach the Paperclip UI from this peer at:  http://${SERVER_NET}/"
PEEREOF
  # 0755 (not 0750) so non-root invocations can at least *find* the script
  # and see its "run as root" message — with 0750, plain `add-wg-peer` from
  # the paperclip user gets the confusing "Permission denied" instead.
  # The script still refuses to run without root, so this isn't a privilege
  # leak.
  chmod 0755 /usr/local/sbin/add-wg-peer

  log "Enabling wg-quick@wg0"
  systemctl enable --now wg-quick@wg0
fi

# ---------- 9. systemd unit (optional) -------------------------------------
if [[ "$SETUP_SYSTEMD" == "1" ]]; then
  log "Writing /etc/systemd/system/paperclip.service"
  PNPM_BIN="$(command -v pnpm)"
  cat > /etc/systemd/system/paperclip.service <<UNIT
[Unit]
Description=Paperclip — open-source orchestration for AI companies
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PAPERCLIP_USER}
Group=${PAPERCLIP_USER}
WorkingDirectory=${PAPERCLIP_HOME}/paperclip
Environment=NODE_ENV=production
Environment=PORT=${PAPERCLIP_PORT}
Environment=HOME=${PAPERCLIP_HOME}
Environment=PATH=${PAPERCLIP_HOME}/.npm-global/bin:${PAPERCLIP_HOME}/.local/bin:${PAPERCLIP_HOME}/.hermes/bin:${PAPERCLIP_HOME}/.claude/bin:${PAPERCLIP_HOME}/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash -lc '${PAPERCLIP_START_CMD}'
Restart=always
RestartSec=5
LimitNOFILE=65535
KillSignal=SIGINT
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable paperclip
  systemctl restart paperclip || systemctl start paperclip
fi

# ---------- done ------------------------------------------------------------
cat <<DONE

${C_GREEN}All done.${C_RESET}

Next steps:
  1. Authenticate each agent client once (interactively) as ${PAPERCLIP_USER}:
       sudo -iu ${PAPERCLIP_USER}
       hermes              # configures ~/.hermes/.env
       claude              # signs in / sets ANTHROPIC_API_KEY
       codex               # 'Sign in with ChatGPT' or API key
       opencode auth login # pick provider, paste key
       gh auth login       # GitHub CLI — device-flow login, optional

  2. Configure Paperclip itself:
       cd ~/paperclip
       cat .env            # review / edit
       # First-run onboarding (only if you didn't seed .env):
       npx paperclipai onboard --yes

  3. Watch the service:
       sudo systemctl status paperclip
       sudo journalctl -u paperclip -f

  4. Hit it:
       http://${PAPERCLIP_DOMAIN/_/<your-server-ip>}/    (via nginx)
       http://127.0.0.1:${PAPERCLIP_PORT}/               (direct)$( [[ "$SETUP_WIREGUARD" == "1" ]] && printf '\n       http://%s/                          (over WireGuard)' "${WIREGUARD_SERVER_IP}" )

$( [[ "$SETUP_WIREGUARD" == "1" ]] && cat <<WG
  4b. WireGuard server is running on UDP ${WIREGUARD_PORT}, subnet ${WIREGUARD_NET}.
      Add a peer (and get a client config + QR code printed):
        sudo add-wg-peer my-laptop                # split tunnel (default)
        sudo add-wg-peer phone --full-tunnel      # route everything via VPN
      Client configs are saved to /etc/wireguard/clients/<name>.conf.
WG
)

  5. Hermes is wired up as the \`hermes_local\` adapter. In the Paperclip UI,
     create an agent with adapterType "hermes_local" and a model like
     "anthropic/claude-sonnet-4". See the adapter README for full options:
       https://github.com/paperclipai/hermes-paperclip-adapter

  6. To update Paperclip later WITHOUT losing the hermes_local registration,
     use the companion script:
       sudo bash update-paperclip.sh
     It stashes your local mods, pulls upstream, restores them, re-runs the
     idempotent overlay (heals the patch if a merge dropped it), rebuilds,
     and restarts the service.

  7. Lock the box down (UFW, key-only SSH, fail2ban, sysctl, auto sec.
     updates) with the companion hardening script. RUN THIS LAST and only
     after a public key for ${PAPERCLIP_USER} is in
     /home/${PAPERCLIP_USER}/.ssh/authorized_keys — the script refuses to
     disable password auth otherwise:

       sudo SSH_USERS="${PAPERCLIP_USER}" bash harden-server.sh

  TIP — to do steps 1, 6 and 7 in one go from your local Mac/Linux machine,
        use the bootstrap script that ships with this repo:

       ./bootstrap.sh ${PAPERCLIP_USER:+--paperclip-user ${PAPERCLIP_USER} }root@<your-server>

DONE
