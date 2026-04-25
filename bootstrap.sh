#!/usr/bin/env bash
# ============================================================================
#  bootstrap.sh — one-shot remote install for the Paperclip VM, run LOCALLY
#                 from your macOS or Linux machine.
# ----------------------------------------------------------------------------
#  What it does (in order, fully automatic):
#    1. Makes sure you have a local SSH key (~/.ssh/id_ed25519) — generates
#       one with no passphrase if you don't, so the rest of the run is
#       non-interactive.
#    2. Pushes your public key into the admin user's authorized_keys on the
#       target host (one password prompt at most — the only interactive
#       moment in the whole flow).
#    3. Uploads setup-paperclip.sh, update-paperclip.sh and harden-server.sh
#       to the target.
#    4. Runs setup-paperclip.sh as root over SSH.
#    5. Installs your public key into the freshly-created paperclip user's
#       authorized_keys (this is what makes the next step lockout-safe).
#    6. Runs harden-server.sh as root over SSH (UFW, key-only SSH,
#       fail2ban, sysctl, …). This is the step that disables password SSH,
#       so it intentionally runs LAST and only after step 5 succeeded.
#    7. Verifies key-only SSH still works for the paperclip user before
#       declaring success.
#
#  Why this exists:
#    Doing setup + hardening manually means a user can lock themselves out
#    by enabling key-only SSH before the key is in place. This script
#    sequences the steps so that's impossible: the hardening step is
#    gated on a working key for the paperclip user.
#
#  Requirements on your local machine:
#    - bash 4+ (macOS: `brew install bash` if you want it, but the system
#      bash works for this script — we don't use 4-only features).
#    - openssh client (ssh, scp, ssh-keygen). macOS ships these.
#    - sshpass is NOT required; we rely on the ssh agent / ControlMaster.
#
#  Requirements on the target:
#    - Fresh Ubuntu 22.04 / 24.04 or Debian 12.
#    - You can reach it as root (or any sudo-capable user) over SSH —
#      either with a password or with a key already installed (e.g. the
#      cloud provider injected one).
#
#  Usage:
#    ./bootstrap.sh user@host
#    ./bootstrap.sh -p 2222 root@1.2.3.4
#    ./bootstrap.sh --domain paperclip.example.com --grant-sudo \
#                   ubuntu@vm.example.com
#
#  Re-running is safe: every remote step is idempotent.
# ============================================================================

set -euo pipefail

# ---------- defaults --------------------------------------------------------
SSH_PORT=22
IDENTITY=""
PAPERCLIP_USER="paperclip"
PAPERCLIP_DOMAIN="_"
NODE_MAJOR="24"
RUN_HARDEN=1
DISABLE_PASSWORDS=1
GRANT_SUDO=0
SETUP_WIREGUARD=0
REMOTE_WORKDIR="/root/paperclip-vm-setup"
# Trusted-IP whitelist: passed to harden-server.sh as TRUSTED_IPS so the
# operator can never lock themselves out via fail2ban / UFW rate-limits.
# By default we auto-detect the local public IP; --no-trust-ip skips that,
# --trust-ip <ip> appends extras (repeatable).
TRUST_LOCAL_IP=1
EXTRA_TRUST_IPS=()

usage() {
  cat <<USAGE
Usage: $0 [options] <user@host>

Provisions Paperclip on a fresh remote VM and applies the hardening
baseline, fully automated from your local machine.

Options:
  -p, --port PORT             SSH port (default: 22)
  -i, --identity FILE         SSH private key to use (default:
                              ~/.ssh/id_ed25519, auto-generated if missing)
      --paperclip-user NAME   Service user name (default: paperclip)
      --domain DOMAIN         nginx server_name (default: catch-all '_')
      --node-major N          Node major to install (default: 24)
      --grant-sudo            Give the paperclip user sudo access
      --wireguard             Install a WireGuard server (UDP 51820) on the
                              remote and add /usr/local/sbin/add-wg-peer
                              for minting client configs
      --no-harden             Skip running harden-server.sh
      --keep-passwords        Leave SSH password auth enabled in hardening
      --trust-ip IP           Whitelist this IP/CIDR on the SSH port and in
                              fail2ban (repeatable). By default the local
                              machine's public IP is auto-detected and
                              trusted as well, so you don't lock yourself
                              out the first time you re-connect.
      --no-trust-ip           Skip the auto-detect of the local public IP.
                              --trust-ip entries are still honoured.
  -h, --help                  Show this help

Examples:
  $0 root@1.2.3.4
  $0 -p 2222 ubuntu@vm.example.com
  $0 --domain paperclip.example.com --grant-sudo root@1.2.3.4
USAGE
}

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
# Real ESC bytes for use inside heredocs (which don't interpret \033).
C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'

# ---------- arg parse -------------------------------------------------------
TARGET=""
while (( $# > 0 )); do
  case "$1" in
    -p|--port)             SSH_PORT="$2"; shift 2 ;;
    -i|--identity)         IDENTITY="$2"; shift 2 ;;
    --paperclip-user)      PAPERCLIP_USER="$2"; shift 2 ;;
    --domain)              PAPERCLIP_DOMAIN="$2"; shift 2 ;;
    --node-major)          NODE_MAJOR="$2"; shift 2 ;;
    --grant-sudo)          GRANT_SUDO=1; shift ;;
    --wireguard)           SETUP_WIREGUARD=1; shift ;;
    --no-harden)           RUN_HARDEN=0; shift ;;
    --keep-passwords)      DISABLE_PASSWORDS=0; shift ;;
    --trust-ip)            EXTRA_TRUST_IPS+=("$2"); shift 2 ;;
    --no-trust-ip)         TRUST_LOCAL_IP=0; shift ;;
    -h|--help)             usage; exit 0 ;;
    --)                    shift; break ;;
    -*)                    die "unknown flag: $1 (use --help)" ;;
    *)
      [[ -z "$TARGET" ]] || die "unexpected extra argument: $1"
      TARGET="$1"; shift ;;
  esac
done
[[ -n "${TARGET:-}" ]] || { usage; exit 2; }

if ! [[ "$TARGET" == *@* ]]; then
  die "TARGET must be in the form user@host (got: '$TARGET')"
fi
ADMIN_USER="${TARGET%@*}"
HOST="${TARGET#*@}"

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  die "SSH port '$SSH_PORT' is not valid"
fi

# ---------- local prereqs ---------------------------------------------------
for cmd in ssh scp ssh-keygen; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing local command: $cmd"
done

# Resolve identity. If user didn't pass -i and they have no key at all,
# generate ed25519. If they passed -i, that file MUST exist.
if [[ -n "$IDENTITY" ]]; then
  [[ -f "$IDENTITY" ]] || die "identity file not found: $IDENTITY"
else
  if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    IDENTITY="$HOME/.ssh/id_ed25519"
  elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
    IDENTITY="$HOME/.ssh/id_rsa"
  else
    log "No local SSH key found — generating $HOME/.ssh/id_ed25519"
    install -d -m 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" \
      -C "$(whoami)@$(hostname)-paperclip-bootstrap"
    IDENTITY="$HOME/.ssh/id_ed25519"
  fi
fi
PUBKEY_FILE="${IDENTITY}.pub"
[[ -f "$PUBKEY_FILE" ]] || die "public key not found beside $IDENTITY (expected $PUBKEY_FILE)"
[[ -s "$PUBKEY_FILE" ]] || die "public key file $PUBKEY_FILE is EMPTY — re-generate it (rm -f $PUBKEY_FILE $IDENTITY then re-run)"
PUBKEY_CONTENT="$(cat "$PUBKEY_FILE")"
# Sanity-check the pubkey looks like a real OpenSSH public key. This catches
# corrupted .pub files early, BEFORE we silently end up writing an empty
# authorized_keys on the remote (grep -qxF "" matches everything).
if ! [[ "$PUBKEY_CONTENT" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-[a-z0-9-]+|sk-(ssh-ed25519|ecdsa-sha2-[a-z0-9-]+)@openssh\.com)\  ]]; then
  die "public key file $PUBKEY_FILE doesn't look like an OpenSSH public key. First 80 chars:
  ${PUBKEY_CONTENT:0:80}
Re-generate with: ssh-keygen -t ed25519 -f $IDENTITY"
fi

log "Using identity: $IDENTITY"
log "Target: ${ADMIN_USER}@${HOST}:${SSH_PORT}"
log "Paperclip user: ${PAPERCLIP_USER}"
log "Domain: ${PAPERCLIP_DOMAIN}"
log "Run hardening: $([[ "$RUN_HARDEN" == "1" ]] && echo yes || echo no)"

# ---------- locate the script bundle next to this file --------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in setup-paperclip.sh update-paperclip.sh harden-server.sh; do
  [[ -f "$SELF_DIR/$f" ]] || die "missing $SELF_DIR/$f — run bootstrap from the repo root"
done

# ---------- SSH ControlMaster (one TCP connection, many commands) ---------
# We deliberately put the socket under ~/.ssh and use just %C as the
# filename (no extra prefix). UNIX socket paths are capped at 104 bytes on
# macOS (108 on Linux), and macOS's default $TMPDIR is
# /var/folders/.../T/ which already eats ~50 chars. ~/.ssh keeps the path
# well under the limit on every platform we target and is already mode
# 700, so it's also the right place security-wise.
install -d -m 700 "$HOME/.ssh"
CONTROL_DIR="$(mktemp -d "$HOME/.ssh/pcb.XXXXXX")"
chmod 700 "$CONTROL_DIR"
SKIP_CLEANUP=0
cleanup() {
  if [[ "$SKIP_CLEANUP" == "1" ]]; then
    return
  fi
  ssh -O exit -o ControlPath="$CONTROL_DIR/%C" -p "$SSH_PORT" \
      "${ADMIN_USER}@${HOST}" 2>/dev/null || true
  rm -rf "$CONTROL_DIR"
}
trap cleanup EXIT

# ---------- rescue path printer -------------------------------------------
# Used when something goes wrong AFTER sshd has been touched. The admin
# ControlMaster session is still authenticated and bypasses sshd's auth
# (it tunnels new sessions through the existing TCP connection), so it's
# our escape hatch when key login is broken.
print_rescue_info() {
  local rescue_ssh
  rescue_ssh="ssh -o ControlPath=\"${CONTROL_DIR}/%C\" -i \"${IDENTITY}\" -p ${SSH_PORT} ${ADMIN_USER}@${HOST}"
  cat >&2 <<RESCUE

${C_RED}!!! RESCUE SHELL AVAILABLE !!!${C_RESET}

The admin SSH ControlMaster session is still open and authenticated.
You can drop into a working shell on ${HOST} WITHOUT re-authenticating
(this works even if password and/or key auth is currently broken):

    ${rescue_ssh}

This session will live for ~10 minutes (ControlPersist=10m). Keep this
terminal open — closing it doesn't kill the master, but losing the path
to ${CONTROL_DIR} does.

Triage commands once you're in:

    ${SUDO}sshd -t                                                  # validate sshd config
    ${SUDO}cat /etc/ssh/sshd_config.d/99-hardening.conf
    ${SUDO}journalctl -u ssh --since '5 min ago' --no-pager

Quick rollback of the hardening sshd drop-in:

    ${SUDO}rm /etc/ssh/sshd_config.d/99-hardening.conf
    ${SUDO}systemctl reload ssh

Re-enable password auth temporarily (lets you reach the box from a
fresh terminal while you debug keys):

    echo 'PasswordAuthentication yes' | ${SUDO}tee /etc/ssh/sshd_config.d/00-emergency.conf
    ${SUDO}systemctl reload ssh

Once you have verified login works from a brand-new terminal, close
the rescue master cleanly with:

    ssh -O exit -o ControlPath="${CONTROL_DIR}/%C" -i "${IDENTITY}" -p ${SSH_PORT} ${ADMIN_USER}@${HOST}

RESCUE
}

SSH_COMMON=(
  -o "ControlMaster=auto"
  -o "ControlPath=$CONTROL_DIR/%C"
  -o "ControlPersist=10m"
  -o "ConnectTimeout=15"
  -o "ServerAliveInterval=30"
  -o "ServerAliveCountMax=4"
  -o "StrictHostKeyChecking=accept-new"
  -i "$IDENTITY"
  -p "$SSH_PORT"
)
SCP_COMMON=(
  -o "ControlMaster=auto"
  -o "ControlPath=$CONTROL_DIR/%C"
  -o "ControlPersist=10m"
  -o "ConnectTimeout=15"
  -o "StrictHostKeyChecking=accept-new"
  -i "$IDENTITY"
  -P "$SSH_PORT"
)

ssh_admin()  { ssh "${SSH_COMMON[@]}" "${ADMIN_USER}@${HOST}" "$@"; }
scp_to()     { scp "${SCP_COMMON[@]}" "$@"; }

# ---------- 1. push key to admin user (one password prompt at worst) ------
log "Ensuring ${ADMIN_USER}@${HOST} accepts our key"
# Try a key-only login first. If that already works (cloud provider injected
# the key, or you've used this host before), we skip the password prompt.
if ssh "${SSH_COMMON[@]}" -o BatchMode=yes -o PreferredAuthentications=publickey \
       "${ADMIN_USER}@${HOST}" 'true' 2>/dev/null; then
  log "Key auth to ${ADMIN_USER}@${HOST} already works — no password needed"
else
  log "Key auth not yet trusted — copying public key (will prompt for password)"
  if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id -i "$PUBKEY_FILE" -p "$SSH_PORT" \
      -o "StrictHostKeyChecking=accept-new" \
      "${ADMIN_USER}@${HOST}" \
      || die "ssh-copy-id failed — check the password and try again"
  else
    # Fallback: append the key over an interactive ssh session.
    cat "$PUBKEY_FILE" | ssh -p "$SSH_PORT" \
      -o "StrictHostKeyChecking=accept-new" \
      "${ADMIN_USER}@${HOST}" '
        set -e
        umask 077
        mkdir -p ~/.ssh
        cat >> ~/.ssh/authorized_keys
        sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys
        chmod 700 ~/.ssh
        chmod 600 ~/.ssh/authorized_keys
      ' || die "manual key install failed"
  fi
fi

# Verify key login *now* before we do anything else.
ssh_admin -o BatchMode=yes -o PreferredAuthentications=publickey 'echo ok' >/dev/null \
  || die "key login still doesn't work for ${ADMIN_USER}@${HOST} — aborting"

# Build a sudo prefix for the admin user (no-op if admin is root).
if [[ "$ADMIN_USER" == "root" ]]; then
  SUDO=""
else
  SUDO="sudo "
fi

# ---------- 2. upload script bundle ---------------------------------------
log "Uploading scripts to ${REMOTE_WORKDIR}"
ssh_admin "${SUDO}install -d -m 0755 -o ${ADMIN_USER} ${REMOTE_WORKDIR}"
scp_to \
  "$SELF_DIR/setup-paperclip.sh" \
  "$SELF_DIR/update-paperclip.sh" \
  "$SELF_DIR/harden-server.sh" \
  "${ADMIN_USER}@${HOST}:${REMOTE_WORKDIR}/"
ssh_admin "chmod +x ${REMOTE_WORKDIR}/*.sh"

# ---------- 3. run setup-paperclip.sh --------------------------------------
log "Running setup-paperclip.sh on the remote (this can take several minutes)"
# Pass our knobs through. SETUP_NGINX/SYSTEMD stay on by default.
ssh_admin "${SUDO}env \
  PAPERCLIP_USER='${PAPERCLIP_USER}' \
  PAPERCLIP_DOMAIN='${PAPERCLIP_DOMAIN}' \
  NODE_MAJOR='${NODE_MAJOR}' \
  GRANT_SUDO='${GRANT_SUDO}' \
  SETUP_WIREGUARD='${SETUP_WIREGUARD}' \
  bash ${REMOTE_WORKDIR}/setup-paperclip.sh"

# ---------- 4. install our key for the paperclip user ---------------------
# This is the lockout-safety prerequisite for the hardening step. We do it
# *before* harden-server.sh so the key check there always passes.
#
# We scp the pubkey to a known temp file on the remote rather than splicing
# it into a heredoc through `printf '%q'`. That eliminates four layers of
# quoting (local bash -> ssh arg -> sshd `sh -c` -> sudo -> bash) that
# previously could collapse to an empty `KEY=`, which then made
# `grep -qxF "" "$AK"` match every line and silently skip the append.
log "Uploading public key to remote"
scp_to "$PUBKEY_FILE" "${ADMIN_USER}@${HOST}:${REMOTE_WORKDIR}/operator.pub"

log "Installing public key for ${PAPERCLIP_USER}@${HOST}"
ssh_admin "${SUDO}bash -s -- '${PAPERCLIP_USER}' '${REMOTE_WORKDIR}/operator.pub'" <<'EOF'
set -euo pipefail
PU="$1"
KEYFILE="$2"
[ -s "$KEYFILE" ] || { echo "[fail] $KEYFILE missing or empty on remote" >&2; exit 1; }
HOME_DIR="$(getent passwd "$PU" | cut -d: -f6)"
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || { echo "[fail] no home for user '$PU'" >&2; exit 1; }
install -d -m 700 -o "$PU" -g "$PU" "$HOME_DIR/.ssh"
AK="$HOME_DIR/.ssh/authorized_keys"
touch "$AK"; chown "$PU:$PU" "$AK"; chmod 600 "$AK"
KEY="$(cat "$KEYFILE")"
[ -n "$KEY" ] || { echo "[fail] read empty key from $KEYFILE" >&2; exit 1; }
grep -qxF "$KEY" "$AK" || printf '%s\n' "$KEY" >> "$AK"
# Verify the key is actually present after the write.
if ! grep -qxF "$KEY" "$AK"; then
  echo "[fail] key not present in $AK after append — $(wc -c < "$AK") bytes, $(wc -l < "$AK") lines" >&2
  exit 1
fi
echo "[ok] $AK now has $(wc -l < "$AK") line(s), $(wc -c < "$AK") bytes"
EOF

# Verify by actually logging in as the paperclip user with the key.
# %C in ControlPath hashes the remote user too, so this transparently uses
# a separate socket from the admin-user master.
log "Verifying key login as ${PAPERCLIP_USER}@${HOST}"
if ! ssh "${SSH_COMMON[@]}" -o BatchMode=yes \
       -o PreferredAuthentications=publickey \
       "${PAPERCLIP_USER}@${HOST}" 'echo ok' >/dev/null 2>&1; then
  die "key login as ${PAPERCLIP_USER} failed — refusing to run hardening (would lock you out). Check sshd config and authorized_keys."
fi

# ---------- 5. run harden-server.sh ---------------------------------------
if [[ "$RUN_HARDEN" == "1" ]]; then
  # Allow the admin user too (so you don't lose the bastion if you set one
  # up later), but always allow paperclip.
  if [[ "$ADMIN_USER" != "root" && "$ADMIN_USER" != "$PAPERCLIP_USER" ]]; then
    SSH_USERS_LIST="${PAPERCLIP_USER} ${ADMIN_USER}"
    # Make sure the admin user also has the key (idempotent). Same scp +
    # quoted-heredoc approach as the paperclip install above.
    ssh_admin "${SUDO}bash -s -- '${ADMIN_USER}' '${REMOTE_WORKDIR}/operator.pub'" <<'EOF'
set -euo pipefail
PU="$1"
KEYFILE="$2"
[ -s "$KEYFILE" ] || { echo "[fail] $KEYFILE missing or empty" >&2; exit 1; }
HOME_DIR="$(getent passwd "$PU" | cut -d: -f6)"
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || { echo "[fail] no home for '$PU'" >&2; exit 1; }
install -d -m 700 -o "$PU" -g "$PU" "$HOME_DIR/.ssh"
AK="$HOME_DIR/.ssh/authorized_keys"
touch "$AK"; chown "$PU:$PU" "$AK"; chmod 600 "$AK"
KEY="$(cat "$KEYFILE")"
[ -n "$KEY" ] || { echo "[fail] empty key in $KEYFILE" >&2; exit 1; }
grep -qxF "$KEY" "$AK" || printf '%s\n' "$KEY" >> "$AK"
grep -qxF "$KEY" "$AK" || { echo "[fail] key missing from $AK after append" >&2; exit 1; }
echo "[ok] $AK now has $(wc -l < "$AK") line(s)"
EOF
  else
    SSH_USERS_LIST="${PAPERCLIP_USER}"
  fi

  # Build the trusted-IPs list passed through to harden-server.sh.
  trust_list=()
  if [[ "$TRUST_LOCAL_IP" == "1" ]]; then
    detected=""
    for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
      detected="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ "$detected" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9a-fA-F:]+)$ ]]; then
        break
      fi
      detected=""
    done
    if [[ -n "$detected" ]]; then
      log "Auto-detected local public IP: ${detected} (will be whitelisted)"
      trust_list+=("$detected")
    else
      warn "Could not auto-detect local public IP — proceeding without an auto-whitelist."
      warn "If you get locked out, re-run with --trust-ip <your-ip>."
    fi
  fi
  for ip in "${EXTRA_TRUST_IPS[@]}"; do
    trust_list+=("$ip")
  done
  TRUSTED_IPS_CSV=""
  if (( ${#trust_list[@]} > 0 )); then
    TRUSTED_IPS_CSV="$(IFS=,; echo "${trust_list[*]}")"
    log "Trusting these IPs on the SSH port + in fail2ban: ${TRUSTED_IPS_CSV}"
  fi

  log "Running harden-server.sh on the remote"
  cat <<HEADSUP

${C_YELLOW}Heads-up: the next step touches sshd.${C_RESET} If hardening misfires, the
existing admin SSH session stays open as a rescue shell. Save this
command somewhere you can paste it from another terminal:

    ssh -o ControlPath="${CONTROL_DIR}/%C" -i "${IDENTITY}" -p ${SSH_PORT} ${ADMIN_USER}@${HOST}

(That path is unique to this run; it's lost if you close this terminal
without copying it. Full triage instructions are printed on failure.)

HEADSUP

  if ! ssh_admin "${SUDO}env \
    SSH_USERS='${SSH_USERS_LIST}' \
    SSH_PORT='${SSH_PORT}' \
    DISABLE_PASSWORDS='${DISABLE_PASSWORDS}' \
    TRUSTED_IPS='${TRUSTED_IPS_CSV}' \
    bash ${REMOTE_WORKDIR}/harden-server.sh"; then
    SKIP_CLEANUP=1
    print_rescue_info
    die "harden-server.sh exited non-zero — see rescue instructions above"
  fi

  # ---------- 6. post-harden verification ---------------------------------
  # The hardening step reloaded sshd. Re-verify key login on a *fresh* TCP
  # connection (the ControlMaster is still bound to the old daemon).
  log "Re-verifying key login on a fresh connection after sshd reload"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=15 \
           -o PreferredAuthentications=publickey \
           -o StrictHostKeyChecking=accept-new \
           -i "$IDENTITY" -p "$SSH_PORT" \
           "${PAPERCLIP_USER}@${HOST}" 'echo ok' >/dev/null 2>&1; then
    SKIP_CLEANUP=1
    print_rescue_info
    die "key login as ${PAPERCLIP_USER} broke after hardening — see rescue instructions above"
  fi
else
  warn "--no-harden: skipping harden-server.sh. The server is NOT yet locked down."
fi

# ---------- done -----------------------------------------------------------
cat <<DONE

${C_GREEN}All done.${C_RESET}

Connect:
    ssh -i ${IDENTITY} -p ${SSH_PORT} ${PAPERCLIP_USER}@${HOST}

Service status:
    ssh -i ${IDENTITY} -p ${SSH_PORT} ${ADMIN_USER}@${HOST} '${SUDO}systemctl status paperclip --no-pager'

Web UI (via nginx):
    http://${PAPERCLIP_DOMAIN/_/$HOST}/

To update Paperclip later:
    ssh -i ${IDENTITY} -p ${SSH_PORT} ${ADMIN_USER}@${HOST} '${SUDO}bash ${REMOTE_WORKDIR}/update-paperclip.sh'

DONE
