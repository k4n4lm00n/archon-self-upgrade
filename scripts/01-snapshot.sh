#!/usr/bin/env bash
# Phase 1: capture the live instance's identity as the rollback anchor.
source "$(dirname "$0")/lib.sh"

detect_live || die "could not find a running process matching '$LIVE_PROC_PATTERN' — is the server up?"

cd "$LIVE_WT" || die "live worktree $LIVE_WT missing"
LIVE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
LIVE_SHA="$(git rev-parse HEAD)"

# Capture the platforms the OLD server currently has up, for the cutover's parity gate.
# The set the new build must restore = these (unless overridden by REQUIRE_PLATFORMS).
OLD_PLATFORMS="$(capture_platforms "$LIVE_PORT")"
[ -n "$OLD_PLATFORMS" ] && log "old active platforms: $OLD_PLATFORMS" \
  || log "WARN: could not read $HEALTH_URL — platform parity will have nothing to require"

cat > "$STATE_FILE" <<JSON
{
  "captured_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "live_worktree": "$LIVE_WT",
  "live_branch": "$LIVE_BRANCH",
  "live_sha": "$LIVE_SHA",
  "live_pgid": "$LIVE_PGID",
  "live_port": "$LIVE_PORT",
  "old_platforms": "$OLD_PLATFORMS",
  "stage_worktree": "$STAGE_WT",
  "stage_branch": "$STAGE_BRANCH"
}
JSON

log "snapshot written to $STATE_FILE:"
cat "$STATE_FILE"
