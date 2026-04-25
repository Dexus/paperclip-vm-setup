#!/usr/bin/env bash
# ============================================================================
#  harden-server.sh — opinionated baseline hardening for the Paperclip VM
# ----------------------------------------------------------------------------
#  This script is independent of setup-paperclip.sh and can be run before or
#  after it. It applies a defense-in-depth baseline to a fresh
#  Ubuntu 22.04/24.04 or Debian 12 box:
#
#    1. SSH:    key-only auth, no root login, modern crypto, AllowUsers
#               whitelist, idle-timeout, drop-in config in
#               /etc/ssh/sshd_config.d/99-hardening.conf, validated with
#               `sshd -t` before the daemon is reloaded.
#    2. UFW:    default-deny incoming, default-allow outgoing, allow the
#               configured SSH port (+ 80/443 if requested).
#    3. Fail2ban: enabled with an sshd jail.
#    4. Unattended-upgrades: security updates installed automatically.
#    5. Kernel/network sysctl hardening
#               (/etc/sysctl.d/99-paperclip-hardening.conf).
#    6. Filesystem & shared-memory protections, sane root umask.
#    7. Login banner (legal notice) on SSH + local TTY.
#    8. Disable common attack-surface services if present (avahi, cups).
#    9. Lock the root account password (key-based root only via console).
#
#  ----  LOCKOUT SAFETY  -----------------------------------------------------
#  Disabling password SSH on a server you only reach via password is a great
#  way to lose access. This script REFUSES to apply key-only SSH unless at
#  least one of the listed SSH users has a non-empty ~/.ssh/authorized_keys
#  with at least one valid-looking public key. Override with FORCE_KEY_ONLY=1
#  ONLY if you know what you're doing (e.g. you're on the console).
#  ---------------------------------------------------------------------------
#
#  ----  TUNABLES (env vars, all optional)  ---------------------------------
#    SSH_USERS            whitespace list of users allowed to SSH in.
#                         Default: "paperclip"
#    SSH_PORT             port sshd listens on. Default: 22
#    ALLOW_HTTP           open 80/tcp in UFW (1/0). Default: 1
#    ALLOW_HTTPS          open 443/tcp in UFW (1/0). Default: 1
#    SETUP_FAIL2BAN       install + enable fail2ban (1/0). Default: 1
#    SETUP_AUTO_UPDATES   enable unattended-upgrades (1/0). Default: 1
#    HARDEN_KERNEL        write sysctl hardening (1/0). Default: 1
#    HARDEN_SSH           apply sshd drop-in (1/0). Default: 1
#    DISABLE_PASSWORDS    set PasswordAuthentication no (1/0). Default: 1
#    LOCK_ROOT_PASSWORD   `passwd -l root` (1/0). Default: 1
#    FORCE_KEY_ONLY       skip the authorized_keys check (1/0). Default: 0
#    BANNER_TEXT          override default /etc/issue.net banner content.
#  ---------------------------------------------------------------------------
#
#  Run as root (or sudo). Idempotent — safe to re-run.
# ============================================================================

set -euo pipefail

SSH_USERS="${SSH_USERS:-paperclip}"
SSH_PORT="${SSH_PORT:-22}"
ALLOW_HTTP="${ALLOW_HTTP:-1}"
ALLOW_HTTPS="${ALLOW_HTTPS:-1}"
SETUP_FAIL2BAN="${SETUP_FAIL2BAN:-1}"
SETUP_AUTO_UPDATES="${SETUP_AUTO_UPDATES:-1}"
HARDEN_KERNEL="${HARDEN_KERNEL:-1}"
HARDEN_SSH="${HARDEN_SSH:-1}"
DISABLE_PASSWORDS="${DISABLE_PASSWORDS:-1}"
LOCK_ROOT_PASSWORD="${LOCK_ROOT_PASSWORD:-1}"
FORCE_KEY_ONLY="${FORCE_KEY_ONLY:-0}"
BANNER_TEXT="${BANNER_TEXT:-}"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0. preflight ----------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root (or with sudo)."
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "This script targets Ubuntu/Debian; got '${ID:-unknown}'." ;;
esac

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  die "SSH_PORT='$SSH_PORT' is not a valid TCP port."
fi

# ---------- 1. SSH key sanity check (anti-lockout) -------------------------
have_keys_for_user() {
  local u="$1" home akf
  home="$(getent passwd "$u" | cut -d: -f6 || true)"
  [[ -n "$home" && -d "$home" ]] || return 1
  akf="$home/.ssh/authorized_keys"
  [[ -s "$akf" ]] || return 1
  # at least one line that looks like an OpenSSH public key
  grep -Eq '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-[a-z0-9-]+|sk-(ssh-ed25519|ecdsa-sha2-[a-z0-9-]+)@openssh\.com) ' \
    "$akf"
}

if [[ "$HARDEN_SSH" == "1" && "$DISABLE_PASSWORDS" == "1" && "$FORCE_KEY_ONLY" != "1" ]]; then
  log "Verifying at least one SSH user has authorized_keys before disabling password auth"
  found_key_user=""
  missing_users=()
  for u in $SSH_USERS; do
    if id "$u" >/dev/null 2>&1; then
      if have_keys_for_user "$u"; then
        found_key_user="$u"
        printf '  %-16s -> has authorized_keys ✓\n' "$u"
      else
        printf '  %-16s -> NO usable authorized_keys ✗\n' "$u"
        missing_users+=("$u")
      fi
    else
      warn "SSH_USERS contains '$u' but that user does not exist yet — skipping"
    fi
  done
  if [[ -z "$found_key_user" ]]; then
    cat >&2 <<EOF

[fail] Refusing to disable SSH password auth: none of the users in
       SSH_USERS='${SSH_USERS}' have a usable ~/.ssh/authorized_keys file.

       Fix this first, then re-run. For example, on your local machine:

         ssh-copy-id -p ${SSH_PORT} <user>@<this-server>

       Or as root on the server:

         install -d -m 700 -o <user> -g <user> /home/<user>/.ssh
         echo 'ssh-ed25519 AAAA... your@key' \\
           >> /home/<user>/.ssh/authorized_keys
         chown <user>:<user> /home/<user>/.ssh/authorized_keys
         chmod 600 /home/<user>/.ssh/authorized_keys

       Override (DANGEROUS, only if you have console access):
         FORCE_KEY_ONLY=1 sudo bash harden-server.sh

EOF
    exit 1
  fi
  if (( ${#missing_users[@]} > 0 )); then
    warn "Some listed SSH users still have no key: ${missing_users[*]}"
    warn "They will not be able to log in after this script runs."
  fi
fi

# ---------- 2. base packages -----------------------------------------------
log "Installing baseline hardening packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
PKGS=(ufw openssh-server ca-certificates)
[[ "$SETUP_FAIL2BAN" == "1" ]] && PKGS+=(fail2ban)
[[ "$SETUP_AUTO_UPDATES" == "1" ]] && PKGS+=(unattended-upgrades apt-listchanges)
apt-get -y install "${PKGS[@]}"

# ---------- 3. SSH hardening ------------------------------------------------
if [[ "$HARDEN_SSH" == "1" ]]; then
  log "Writing /etc/ssh/sshd_config.d/99-hardening.conf"

  # The main /etc/ssh/sshd_config on Ubuntu 22.04+ / Debian 12 already has
  # `Include /etc/ssh/sshd_config.d/*.conf`. Verify and bail otherwise so we
  # don't write a no-op file.
  if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    warn "sshd_config does not Include /etc/ssh/sshd_config.d/*.conf — adding it"
    printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> /etc/ssh/sshd_config
  fi

  # Build the AllowUsers line from existing accounts only.
  allow_users_line=""
  for u in $SSH_USERS; do
    if id "$u" >/dev/null 2>&1; then
      allow_users_line+="$u "
    fi
  done
  allow_users_line="${allow_users_line% }"

  password_auth="no"
  kbd_auth="no"
  if [[ "$DISABLE_PASSWORDS" != "1" ]]; then
    password_auth="yes"
    kbd_auth="yes"
    warn "DISABLE_PASSWORDS=0 — leaving password auth ENABLED. Not recommended."
  fi

  install -d -m 0755 /etc/ssh/sshd_config.d
  install -m 0644 /dev/null /etc/ssh/sshd_config.d/99-hardening.conf
  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<SSHEOF
# Managed by harden-server.sh — re-run the script to update.
# A drop-in: anything here overrides earlier directives in sshd_config.

Port ${SSH_PORT}
Protocol 2
AddressFamily any

# --- Auth -----------------------------------------------------------------
PermitRootLogin no
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication ${kbd_auth}
ChallengeResponseAuthentication ${kbd_auth}
PermitEmptyPasswords no
UsePAM yes
PubkeyAuthentication yes
AuthenticationMethods publickey$( [[ "$DISABLE_PASSWORDS" != "1" ]] && echo " password" )
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30
$( [[ -n "$allow_users_line" ]] && echo "AllowUsers ${allow_users_line}" )

# --- Hygiene --------------------------------------------------------------
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
PermitUserEnvironment no
GatewayPorts no
TCPKeepAlive no
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE

# --- Modern crypto (OpenSSH 8+) ------------------------------------------
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,sntrup761x25519-sha512@openssh.com,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256
PubkeyAcceptedAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256

# --- Banner ---------------------------------------------------------------
Banner /etc/issue.net
SSHEOF

  # Remove weak host keys, keep only ed25519 + rsa.
  if [[ -f /etc/ssh/ssh_host_dsa_key ]]; then
    log "Removing legacy DSA host key"
    rm -f /etc/ssh/ssh_host_dsa_key /etc/ssh/ssh_host_dsa_key.pub
  fi
  if [[ -f /etc/ssh/ssh_host_ecdsa_key ]]; then
    log "Removing ECDSA host key (ed25519 + RSA are preferred)"
    rm -f /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_ecdsa_key.pub
  fi
  # Make sure ed25519 exists (was generated at install time on most distros,
  # but be defensive).
  if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
    ssh-keygen -q -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ''
  fi

  # Validate before reloading so a bad config doesn't kill the daemon.
  if ! sshd -t; then
    die "sshd config validation failed — refusing to reload. Fix the errors above."
  fi
  log "Reloading ssh"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || \
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
fi

# ---------- 4. UFW firewall -------------------------------------------------
log "Configuring UFW (default deny incoming, allow outgoing)"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw limit "${SSH_PORT}/tcp" comment 'ssh (rate-limited)'
[[ "$ALLOW_HTTP"  == "1" ]] && ufw allow 80/tcp  comment 'http'
[[ "$ALLOW_HTTPS" == "1" ]] && ufw allow 443/tcp comment 'https'
ufw logging low
yes | ufw enable >/dev/null
ufw status verbose || true

# ---------- 5. fail2ban -----------------------------------------------------
if [[ "$SETUP_FAIL2BAN" == "1" ]]; then
  log "Configuring fail2ban (sshd jail)"
  install -d -m 0755 /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/paperclip-hardening.local <<F2BEOF
# Managed by harden-server.sh
[DEFAULT]
bantime   = 1h
findtime  = 10m
maxretry  = 5
backend   = systemd
banaction = ufw

[sshd]
enabled  = true
port     = ${SSH_PORT}
mode     = aggressive
maxretry = 3
F2BEOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
fi

# ---------- 6. unattended security upgrades --------------------------------
if [[ "$SETUP_AUTO_UPDATES" == "1" ]]; then
  log "Enabling unattended-upgrades for security updates"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<APTEOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APTEOF

  cat > /etc/apt/apt.conf.d/52unattended-upgrades-paperclip <<APTEOF
// Managed by harden-server.sh
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=\${distro_codename},label=Debian-Security";
    "origin=Ubuntu,archive=\${distro_codename}-security";
    "origin=UbuntuESMApps,archive=\${distro_codename}-apps-security";
    "origin=UbuntuESM,archive=\${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
APTEOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
fi

# ---------- 7. kernel / network sysctl hardening ---------------------------
if [[ "$HARDEN_KERNEL" == "1" ]]; then
  log "Writing /etc/sysctl.d/99-paperclip-hardening.conf"
  cat > /etc/sysctl.d/99-paperclip-hardening.conf <<SYSCTLEOF
# Managed by harden-server.sh

# --- Network ---------------------------------------------------------------
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.tcp_rfc1337 = 1

# --- Kernel ----------------------------------------------------------------
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.kexec_load_disabled = 1
kernel.sysrq = 0
kernel.perf_event_paranoid = 3

# --- Filesystem ------------------------------------------------------------
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
SYSCTLEOF
  sysctl --system >/dev/null
fi

# ---------- 8. login banner ------------------------------------------------
log "Installing login banner (/etc/issue.net)"
if [[ -z "$BANNER_TEXT" ]]; then
  BANNER_TEXT='********************************************************************
*                       AUTHORIZED ACCESS ONLY                       *
*                                                                    *
* All activity on this system is logged and monitored. Unauthorized  *
* access or use is prohibited and may result in civil and/or         *
* criminal penalties. Disconnect immediately if you are not an       *
* authorized user.                                                   *
********************************************************************'
fi
printf '%s\n' "$BANNER_TEXT" > /etc/issue.net
# Local TTY banner, too.
printf '%s\n' "$BANNER_TEXT" > /etc/issue

# ---------- 9. lock down attack-surface services ---------------------------
log "Disabling unused attack-surface services if present"
for svc in avahi-daemon.service avahi-daemon.socket cups.service cups.socket \
           rpcbind.service rpcbind.socket bluetooth.service; do
  if systemctl list-unit-files "$svc" >/dev/null 2>&1 && \
     systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
    printf '  disabled %s\n' "$svc"
  fi
done

# ---------- 10. root account --------------------------------------------------
if [[ "$LOCK_ROOT_PASSWORD" == "1" ]]; then
  log "Locking root account password (console + key root login still work)"
  passwd -l root >/dev/null
fi

# ---------- 11. misc tightening --------------------------------------------
log "Tightening misc permissions"
# Cron files should not be world-readable.
chmod -R go-rwx /etc/cron.d /etc/cron.daily /etc/cron.hourly \
                /etc/cron.weekly /etc/cron.monthly 2>/dev/null || true
chmod 600 /etc/crontab 2>/dev/null || true
# Restrictive umask for new shells (system-wide).
if ! grep -q '^UMASK\s\+027' /etc/login.defs 2>/dev/null; then
  sed -i 's/^UMASK.*/UMASK\t\t027/' /etc/login.defs || true
fi
# Disable core dumps for SUID programs (defense in depth).
if ! grep -q '^\* hard core 0' /etc/security/limits.conf 2>/dev/null; then
  printf '\n* hard core 0\n' >> /etc/security/limits.conf
fi

# ---------- done -----------------------------------------------------------
cat <<DONE

\033[1;32mServer hardening applied.\033[0m

Quick checklist:
  - SSH:       port ${SSH_PORT}, key-only=$([[ "$DISABLE_PASSWORDS" == "1" ]] && echo yes || echo NO),
               AllowUsers='${SSH_USERS}'
  - Firewall:  ufw active — $(ufw status | sed -n '1p')
  - fail2ban:  $([[ "$SETUP_FAIL2BAN" == "1" ]] && echo enabled || echo skipped)
  - Auto sec.: $([[ "$SETUP_AUTO_UPDATES" == "1" ]] && echo enabled || echo skipped)
  - Kernel:    $([[ "$HARDEN_KERNEL" == "1" ]] && echo sysctl drop-in installed || echo skipped)
  - Root pwd:  $([[ "$LOCK_ROOT_PASSWORD" == "1" ]] && echo locked || echo unchanged)

\033[1;33mBefore you log out:\033[0m open a SECOND ssh session to verify you can
still log in with your key. If you can't, fix it from the active session —
once you log out, a broken sshd config can lock you out for good.

  ssh -p ${SSH_PORT} <user>@<this-server>

To re-run with different options, see the env vars at the top of this script.
DONE
