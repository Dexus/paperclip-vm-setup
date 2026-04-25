#!/usr/bin/env bash
# ============================================================================
#  update-paperclip.sh — safe upstream sync for a Paperclip install made by
#  setup-paperclip.sh.
#
#  Workflow:
#    1. Stop the paperclip systemd service.
#    2. As the paperclip user:
#         a. Stash any uncommitted working-tree changes (this includes the
#            hermes_local registration patch the overlay tool added).
#         b. git pull --ff-only origin <branch>      (no rewriting of history)
#         c. git stash pop  (best-effort; conflicts are surfaced, not hidden)
#         d. Re-run .paperclip-local/apply-overlays.sh — idempotent, so it's
#            a no-op when the patch is intact, but it heals the file if a
#            merge dropped the sentinel block.
#         e. pnpm install   (picks up upstream dep changes)
#         f. pnpm build
#    3. Restart the systemd service and tail the last few log lines.
#
#  Failure modes that DO NOT corrupt your install:
#    - Pull conflicts: the script aborts before touching anything else, the
#      stash is preserved (`git stash list`), and the service is left stopped
#      so you can resolve cleanly.
#    - Stash-pop conflicts (upstream touched the same lines as a local
#      change): the script aborts. The conflict markers are left in place
#      for you to resolve, then re-run with `--resume`.
#    - Overlay refusal (upstream changed the registry shape): apply-overlays
#      prints guidance and exits non-zero; the rest of the build is skipped.
#
#  Tunables (env vars, all optional):
#    PAPERCLIP_USER   — defaults to "paperclip"
#    PAPERCLIP_DIR    — defaults to "/home/$PAPERCLIP_USER/paperclip"
#    PAPERCLIP_BRANCH — defaults to "" (=> use whatever branch is checked out)
#    SKIP_BUILD=1     — skip pnpm install + build (you'll do it yourself)
#    SKIP_RESTART=1   — skip systemctl restart
#
#  Flags:
#    --resume   skip the stash/pull steps and just re-apply overlay + build +
#               restart. Use this after manually resolving a conflict.
#    --dry-run  show what would be done, don't change anything.
# ============================================================================

set -euo pipefail

PAPERCLIP_USER="${PAPERCLIP_USER:-paperclip}"
PAPERCLIP_DIR="${PAPERCLIP_DIR:-/home/${PAPERCLIP_USER}/paperclip}"
PAPERCLIP_BRANCH="${PAPERCLIP_BRANCH:-}"

RESUME=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --resume)  RESUME=1  ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '1,/^# =\{4,\}$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [[ "$DRY_RUN" == "1" ]]; then echo "+ $*"; else eval "$*"; fi; }

[[ $EUID -eq 0 ]] || die "Run as root (or with sudo)."
id "$PAPERCLIP_USER" >/dev/null 2>&1 || die "user '$PAPERCLIP_USER' does not exist"
[[ -d "$PAPERCLIP_DIR/.git" ]] || die "$PAPERCLIP_DIR is not a git checkout"

as_paperclip() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "+ sudo -u $PAPERCLIP_USER -H bash -lc \"$1\""
  else
    sudo -u "$PAPERCLIP_USER" -H bash -lc "$1"
  fi
}

# ---------- 1. stop the service --------------------------------------------
if systemctl list-unit-files paperclip.service >/dev/null 2>&1; then
  log "Stopping paperclip.service"
  run "systemctl stop paperclip.service || true"
else
  warn "paperclip.service not installed — running update without service control"
fi

# ---------- 2. stash + pull (skipped on --resume) --------------------------
STASH_TAG="paperclip-update-$(date +%s)"

if [[ "$RESUME" == "0" ]]; then
  log "Stashing working-tree changes (if any)"
  as_paperclip "
    set -e
    cd '$PAPERCLIP_DIR'
    if ! git diff --quiet --ignore-submodules HEAD; then
      git stash push --include-untracked -m '$STASH_TAG'
      echo '[stash] saved as: $STASH_TAG'
    else
      echo '[stash] working tree clean — nothing to stash'
    fi
  "

  log "Fetching + fast-forwarding"
  if [[ -n "$PAPERCLIP_BRANCH" ]]; then
    as_paperclip "cd '$PAPERCLIP_DIR' && git fetch origin '$PAPERCLIP_BRANCH' && git checkout '$PAPERCLIP_BRANCH' && git pull --ff-only origin '$PAPERCLIP_BRANCH'"
  else
    as_paperclip "cd '$PAPERCLIP_DIR' && git fetch origin && git pull --ff-only"
  fi

  log "Re-applying stash (if we made one)"
  as_paperclip "
    set -e
    cd '$PAPERCLIP_DIR'
    if git stash list | grep -q '$STASH_TAG'; then
      if ! git stash pop; then
        echo
        echo '!!! stash pop produced conflicts.'
        echo '!!! resolve them, then re-run:  sudo bash update-paperclip.sh --resume'
        exit 7
      fi
    fi
  " || die "stash pop failed; see above. Service is stopped; resolve and run with --resume."
fi

# ---------- 3. heal the overlay (idempotent) -------------------------------
if [[ -x "$PAPERCLIP_DIR/.paperclip-local/apply-overlays.sh" ]]; then
  log "Re-applying .paperclip-local overlays (idempotent)"
  as_paperclip "cd '$PAPERCLIP_DIR' && ./.paperclip-local/apply-overlays.sh" \
    || die "overlay application failed — refusing to build/restart on top of a half-patched tree."
else
  warn ".paperclip-local/apply-overlays.sh not found or not executable. " \
       "Skipping overlay step. (If this install came from setup-paperclip.sh, " \
       "something has gone wrong — investigate.)"
fi

# ---------- 4. install + build ---------------------------------------------
if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  warn "SKIP_BUILD=1 — not running pnpm install / build."
else
  log "pnpm install + build"
  as_paperclip "
    set -e
    cd '$PAPERCLIP_DIR'
    pnpm install
    pnpm build
  "
fi

# ---------- 5. restart the service -----------------------------------------
if [[ "${SKIP_RESTART:-0}" == "1" ]]; then
  warn "SKIP_RESTART=1 — leaving service stopped. Start it with: systemctl start paperclip"
elif systemctl list-unit-files paperclip.service >/dev/null 2>&1; then
  log "Starting paperclip.service"
  run "systemctl start paperclip.service"
  sleep 2
  systemctl --no-pager --lines=10 status paperclip.service || true
fi

log "Update complete. Current commit:"
as_paperclip "cd '$PAPERCLIP_DIR' && git --no-pager log -1 --oneline"
