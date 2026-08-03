#!/usr/bin/env bash
# Phase 4: boot the staged build in isolation on SMOKE_PORT with ALL credential-like env
# vars blanked, so every platform adapter's presence-gate is false and it connects to nothing
# (no messenger queue theft, no forge polling). The server self-loads its env file (dotenv),
# which won't override an already-set var — so we set creds EMPTY rather than unset them.
# Success = READY_MARKER in the log + HTTP responds. Then it is killed.
source "$(dirname "$0")/lib.sh"
[ -d "$STAGE_WT" ] || die "no staging worktree — run 02-stage.sh first"

SMOKE_LOG="$LOG_DIR/smoke.log"
: > "$SMOKE_LOG"

if port_busy "$SMOKE_PORT"; then die "port $SMOKE_PORT already in use"; fi

# Messenger-agnostic isolation: point ARCHON_HOME at a scratch dir holding a credential-blanked
# copy of the env file. The server loads it (override) as user-scope env => every adapter's
# presence-gate is false => no adapter starts, while DB/other config still load. No HOME
# override, nothing written into the worktree.
SMOKE_ARCHON_HOME="$UPGRADE_DIR/smoke-archon"
rm -rf "$SMOKE_ARCHON_HOME"; mkdir -p "$SMOKE_ARCHON_HOME"
write_scrubbed_env_file "$ENV_FILE" "$SMOKE_ARCHON_HOME/.env"
log "smoke isolation: ARCHON_HOME=$SMOKE_ARCHON_HOME ($(grep -cE '=$' "$SMOKE_ARCHON_HOME/.env") creds blanked)"

cd "$STAGE_WT" || die "cannot cd staging"
log "booting staged build on :$SMOKE_PORT (adapters disabled via scrubbed ARCHON_HOME) ..."
setsid env "${CLAUDE_SCRUB[@]}" "${SELFUPGRADE_SCRUB[@]}" ARCHON_HOME="$SMOKE_ARCHON_HOME" \
  ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1 PATH="$BIN_PATH_PREPEND:$PATH" PORT="$SMOKE_PORT" \
  $DEV_CMD </dev/null >"$SMOKE_LOG" 2>&1 &
SMOKE_PGID="$!"

cleanup(){ kill -TERM -"$SMOKE_PGID" 2>/dev/null; kill -KILL -"$SMOKE_PGID" 2>/dev/null;
  rm -rf "$SMOKE_ARCHON_HOME"; }
trap cleanup EXIT

ok=0
for i in $(seq 1 120); do
  if grep -q "$READY_MARKER" "$SMOKE_LOG" 2>/dev/null; then ok=1; log "$READY_MARKER after ${i}s"; break; fi
  if ! kill -0 "$SMOKE_PGID" 2>/dev/null; then tail -30 "$SMOKE_LOG"; die "smoke server died early — see $SMOKE_LOG"; fi
  sleep 1
done
[ "$ok" = 1 ] || { tail -30 "$SMOKE_LOG"; die "'$READY_MARKER' not seen in 120s — see $SMOKE_LOG"; }

# HTTP liveness check.
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SMOKE_PORT/" 2>/dev/null)"
log "HTTP / -> $code"
case "$code" in 2*|3*|4*) log "HTTP responding" ;; *) die "no HTTP response on :$SMOKE_PORT" ;; esac

log "SMOKE OK — staged build boots and serves. Tearing down."
