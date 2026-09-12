#!/usr/bin/env bash
# Phase 5: THE CUTOVER. Destructive. Must run fully detached (setsid) because the agent
# that launches it lives inside the live server's process group it is about to kill.
# Launch with:  setsid bash 05-cutover.sh </dev/null >LOG 2>&1 &
#
# The new build must pass the HEALTH GATE (run_health_gate, see lib.sh): the default gate
# (startup + health endpoint + platform parity) plus any operator rollback constraints
# (REQUIRE_LOG/FORBID_LOG, CUTOVER_DEADLINE, HEALTH_CMD/HEALTH_HOOK, CONFIRM_CMD). If the
# gate fails, it kills the new server and restarts the OLD worktree on LIVE_PORT, then
# re-checks basic health. The old worktree is never modified, so rollback is a clean
# restart from a known-good tree. Outcome -> cutover-status.json and NOTIFY_CMD.
source "$(dirname "$0")/lib.sh"
[ -f "$STATE_FILE" ] || die "no state.json"
[ -d "$STAGE_WT" ]   || die "no staging worktree"

OLD_WT="$(state_get live_worktree)"
OLD_PGID="$(state_get live_pgid)"
OLD_PLATFORMS="$(state_get old_platforms)"; export OLD_PLATFORMS   # required set for the parity gate
CUT_LOG="$LOG_DIR/cutover.log"
NEW_LOG="$LOG_DIR/server-new.log"
OLD_LOG="$LOG_DIR/server-rollback.log"
STATUS="$UPGRADE_DIR/cutover-status.json"

exec >>"$CUT_LOG" 2>&1
# Guarantee adapter creds regardless of how this detached process was launched.
if [ -f "$ENV_FILE" ]; then set -a; source "$ENV_FILE"; set +a; fi
log "==== cutover started (pid $$) ===="
log "old: $OLD_WT (pgid $OLD_PGID)  ->  new: $STAGE_WT"
log "health gate: parity=$([ "$SKIP_PLATFORM_PARITY" = 1 ] && echo off || echo "require[${REQUIRE_PLATFORMS:-$OLD_PLATFORMS}]") deadline=${CUTOVER_DEADLINE}s require_log=[${REQUIRE_LOG}] forbid_log=[${FORBID_LOG}] health_cmd=$([ -n "$HEALTH_CMD" ] && echo yes || echo no) confirm=$([ -n "$CONFIRM_CMD" ] && echo "yes(${CONFIRM_TIMEOUT_S}s)" || echo no)"
write_status(){ echo "{\"phase\":\"$1\",\"detail\":\"$2\",\"utc\":\"$(date -u +%FT%TZ)\"}" > "$STATUS"; }
# The cold-start script (start-current.sh) reads $POINTER before the cutover records; keep
# it pointed at whatever this run leaves serving, or the next cold start boots the OLD build.
POINTER="${POINTER:-$HOME/.archon/.local/current-live.json}"
write_pointer(){ # $1 = worktree ; $2 = pgid
  mkdir -p "$(dirname "$POINTER")" 2>/dev/null
  printf '{"worktree":"%s","branch":"%s","sha":"%s","pgid":"%s","port":"%s","platforms":"%s","started_utc":"%s"}\n' \
    "$1" "$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)" "$(git -C "$1" rev-parse HEAD 2>/dev/null)" \
    "$2" "$LIVE_PORT" "$(capture_platforms "$LIVE_PORT")" "$(date -u +%FT%TZ)" > "$POINTER" \
    && log "pointer $POINTER -> $1" || log "WARN: could not write pointer $POINTER"
}
notify(){ [ -n "$NOTIFY_CMD" ] && eval "$NOTIFY_CMD \"archon-self-upgrade: $1\"" || true; }

write_status starting "settling ${CUTOVER_SETTLE}s"
sleep "$CUTOVER_SETTLE"

stop_group(){ # $1 = pgid
  kill -TERM -"$1" 2>/dev/null
  for i in $(seq 1 15); do kill -0 -"$1" 2>/dev/null || return 0; sleep 1; done
  kill -KILL -"$1" 2>/dev/null
}

start_server(){ # $1 = worktree ; $2 = logfile ; echoes new pgid
  cd "$1" || return 1
  # Scrub CLAUDE_* and this workflow's own config vars so the long-lived server carries neither.
  setsid env "${CLAUDE_SCRUB[@]}" "${SELFUPGRADE_SCRUB[@]}" ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1 \
    PATH="$BIN_PATH_PREPEND:$PATH" PORT="$LIVE_PORT" \
    $DEV_CMD </dev/null >"$2" 2>&1 &
  echo "$!"
}

# --- stop old ---
# Re-detect the live group in case the server was restarted since snapshot; stop both the
# snapshot pgid and any freshly-detected one so we never orphan the old server.
STOP_LIST="$OLD_PGID"
if detect_live && [ -n "${LIVE_PGID:-}" ] && [ "$LIVE_PGID" != "$OLD_PGID" ]; then
  log "note: live pgid is now $LIVE_PGID (snapshot had $OLD_PGID) — stopping both"
  STOP_LIST="$OLD_PGID $LIVE_PGID"
fi
write_status stopping "pgids: $STOP_LIST"
for pg in $STOP_LIST; do log "stopping server group $pg ..."; stop_group "$pg"; done
for i in $(seq 1 30); do port_busy "$LIVE_PORT" || break; sleep 1; done
port_busy "$LIVE_PORT" && log "WARN: port $LIVE_PORT still busy after stop"

# --- start new + apply the full health gate ---
write_status starting_new "$STAGE_WT"
: > "$NEW_LOG"
NEW_PGID="$(start_server "$STAGE_WT" "$NEW_LOG")"
log "new server launched from $STAGE_WT (pgid $NEW_PGID)"
write_status checking "applying health gate to new build"

if run_health_gate "$NEW_LOG" full; then
  write_status success "new build live from $STAGE_WT (pgid $NEW_PGID)"
  write_pointer "$STAGE_WT" "$NEW_PGID"
  log "==== CUTOVER SUCCESS — new build serving on :$LIVE_PORT ===="
  notify "SUCCESS — now serving from $STAGE_WT on :$LIVE_PORT"
  exit 0
fi

# --- ROLLBACK (a health-gate constraint failed) ---
log "==== new build FAILED the health gate — ROLLING BACK ===="
write_status rolling_back "killing new pgid $NEW_PGID, restoring $OLD_WT"
stop_group "$NEW_PGID"
for i in $(seq 1 30); do port_busy "$LIVE_PORT" || break; sleep 1; done

: > "$OLD_LOG"
RB_PGID="$(start_server "$OLD_WT" "$OLD_LOG")"
log "old server relaunched from $OLD_WT (pgid $RB_PGID)"
if run_health_gate "$OLD_LOG" basic; then
  write_status rolled_back "link restored from $OLD_WT (pgid $RB_PGID); upgrade aborted"
  write_pointer "$OLD_WT" "$RB_PGID"
  log "==== ROLLBACK OK — original build restored, link back ===="
  notify "ROLLED BACK — new build failed the health gate, original restored, link back"
  exit 2
fi

write_status FAILED "rollback did not reach healthy — MANUAL INTERVENTION NEEDED (see $OLD_LOG)"
log "==== FATAL: rollback unhealthy — manual intervention required ===="
notify "FAILED — rollback unhealthy, MANUAL INTERVENTION NEEDED"
exit 3
