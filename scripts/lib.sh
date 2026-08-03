#!/usr/bin/env bash
# Shared config + helpers for the archon-self-upgrade toolkit (manual/standalone form).
# Sourced by every phase script. No side effects beyond defining vars/functions.
#
# Messenger-agnostic, two-remote (`upstream` + `myfork`) counterpart of the canonical
# workflow in ../archon-self-upgrade.yaml. All values are env-overridable.
set -uo pipefail

# Where runtime state/logs live (state.json, cutover-status.json, logs/). Override freely.
UPGRADE_DIR="${ARCHON_UPGRADE_DIR:-$HOME/.archon/.local/upgrade}"
STATE_FILE="$UPGRADE_DIR/state.json"
LOG_DIR="$UPGRADE_DIR/logs"
mkdir -p "$LOG_DIR"

# ---- Remotes / target (prerequisites) ----
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/coleam00/Archon}"
FORK_REMOTE="${FORK_REMOTE:-myfork}"
TARGET_REF="${TARGET_REF:-}"           # empty => resolved to the fork HEAD branch in 02-stage

# ---- Ports / staging worktree ----
LIVE_PORT="${LIVE_PORT:-3090}"
SMOKE_PORT="${SMOKE_PORT:-3091}"
STAGE_WT="${STAGE_WT:-$HOME/worktrees/archon-upgrade-next}"
STAGE_BRANCH="${STAGE_BRANCH:-archon-upgrade-next}"

# ---- Commands (empty = skip that step) ----
LIVE_PROC_PATTERN="${LIVE_PROC_PATTERN:-bun --watch src/index.ts}"
DEV_CMD="${DEV_CMD:-bun run dev}"
INSTALL_CMD="${INSTALL_CMD:-bun install}"
TYPECHECK_CMD="${TYPECHECK_CMD:-bun run type-check}"
BUILD_CMD="${BUILD_CMD:-bun run build}"
TEST_CMD="${TEST_CMD:-}"
BIN_PATH_PREPEND="${BIN_PATH_PREPEND:-$HOME/.bun/bin}"

# ═══════════════════════════════════════════════════════════════════════════════════════
# HEALTH GATE — the set of rollback constraints applied to the NEW build after cutover.
# If any constraint fails (or the deadline elapses) the cutover rolls back. The DEFAULT
# gate is generic and platform-agnostic:
#   1. READY_MARKER appears in the new server log (startup finished), within CUTOVER_DEADLINE
#   2. the health endpoint reports status:ok AND every platform that was active on the OLD
#      server is active again (platform parity) — so breaking ANY integration rolls back.
# Operators add their OWN constraints via the knobs below (all optional). See docs/06.
# ═══════════════════════════════════════════════════════════════════════════════════════
READY_MARKER="${READY_MARKER:-server_ready}"     # log line meaning startup finished
CUTOVER_DEADLINE="${CUTOVER_DEADLINE:-150}"      # max seconds to become healthy => "rollback if startup > N"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:$LIVE_PORT/api/health}"
SKIP_PLATFORM_PARITY="${SKIP_PLATFORM_PARITY:-0}"  # 1 = don't require the old platforms to return
REQUIRE_PLATFORMS="${REQUIRE_PLATFORMS:-}"         # ';'-list overriding the auto-captured OLD_PLATFORMS
REQUIRE_LOG="${REQUIRE_LOG:-}"    # ';'-list of regexes that MUST appear in the new log
FORBID_LOG="${FORBID_LOG:-}"      # ';'-list of regexes that, if ANY appears, roll back
HEALTH_CMD="${HEALTH_CMD:-}"      # arbitrary command; must exit 0 (env: NEW_LOG, SERVER_URL, LIVE_PORT)
HEALTH_HOOK="${HEALTH_HOOK:-}"    # path to an executable operator hook; must exit 0 (same env)
CONFIRM_CMD="${CONFIRM_CMD:-}"    # blocks until a human confirms; non-zero/timeout => rollback
CONFIRM_TIMEOUT_S="${CONFIRM_TIMEOUT_S:-600}"   # confirmation window (default 10 min)

# ---- Cutover knobs ----
CUTOVER_SETTLE="${CUTOVER_SETTLE:-45}"
CARRY_LIVE_COMMITS="${CARRY_LIVE_COMMITS:-0}"
ENV_FILE="${ENV_FILE:-$HOME/.archon/.env}"   # sourced by cutover for adapter creds
NOTIFY_CMD="${NOTIFY_CMD:-}"                  # optional: `$NOTIFY_CMD "<message>"` on outcome
SCRUB_ENV_VARS="${SCRUB_ENV_VARS:-}"         # extra env var NAMES to strip for the smoke boot

# Scrub CLAUDE_* so a child server is not detected as a nested Claude agent.
CLAUDE_SCRUB=(-u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH \
  -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS -u CLAUDE_CODE_SESSION_ID)

# This workflow's OWN config vars. They must NOT leak into the long-lived server we launch:
# the server would carry them, and the NEXT upgrade (a subprocess of that server) would inherit
# them — e.g. a stale REQUIRE_LOG / TARGET_REF silently changing its behavior. start_server and
# the smoke boot strip these so every server starts with a clean, config-free environment.
SELFUPGRADE_SCRUB=()
for _v in UPGRADE_DIR ARCHON_UPGRADE_DIR UPSTREAM_REMOTE UPSTREAM_URL FORK_REMOTE TARGET_REF \
  STAGE_WT STAGE_BRANCH LIVE_PROC_PATTERN DEV_CMD INSTALL_CMD TYPECHECK_CMD BUILD_CMD TEST_CMD \
  BIN_PATH_PREPEND READY_MARKER CUTOVER_DEADLINE HEALTH_URL SKIP_PLATFORM_PARITY REQUIRE_PLATFORMS \
  REQUIRE_LOG FORBID_LOG HEALTH_CMD HEALTH_HOOK CONFIRM_CMD CONFIRM_TIMEOUT_S SCRUB_ENV_VARS \
  CUTOVER_SETTLE CARRY_LIVE_COMMITS ENV_FILE NOTIFY_CMD OLD_PLATFORMS; do
  SELFUPGRADE_SCRUB+=(-u "$_v")
done; unset _v

ts(){ date -u +%H:%M:%S; }
log(){ echo "[$(ts)] $*"; }
die(){ echo "[$(ts)] FATAL: $*" >&2; exit 1; }

# Messenger-agnostic smoke isolation. The server loads its user-scope env from
# `getArchonEnvPath()`, which honors ARCHON_HOME, with override:true. So for the smoke boot we
# point ARCHON_HOME at a scratch dir holding a COPY of the real env file with every credential
# blanked — the server loads that (override), every adapter's presence-gate (`Boolean(env.X)`)
# is false => no adapter starts, while DB/other config still load. No HOME override (Claude
# global auth via ~/.claude still works), no file left in the worktree (nothing to leak into the
# cutover). Names no platform.
_CRED_NAME_RE='(TOKEN|SECRET|API_?KEY|WEBHOOK|PASSWORD|PASSWD|CREDENTIAL|BOT_|_BOT)'

# Copy env file $1 to $2, blanking the VALUE of every credential-like variable (plus any
# SCRUB_ENV_VARS) and keeping all other lines verbatim.
write_scrubbed_env_file(){
  local src="$1" dst="$2" line name extra=" $SCRUB_ENV_VARS "
  mkdir -p "$(dirname "$dst")"
  [ -f "$src" ] || { : > "$dst"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) printf '%s\n' "$line" ;;
      *=*)
        name="${line%%=*}"; name="${name#export }"; name="${name## }"
        if printf '%s' "$name" | grep -Eq "^[A-Za-z_][A-Za-z0-9_]*$" \
           && { printf '%s' "$name" | grep -Eq "$_CRED_NAME_RE" || [[ "$extra" == *" $name "* ]]; }; then
          printf '%s=\n' "$name"
        else printf '%s\n' "$line"; fi ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$src" > "$dst"
}

detect_live() {
  local watch_pid cwd
  watch_pid="$(pgrep -f "$LIVE_PROC_PATTERN" | head -1)"
  [ -n "$watch_pid" ] || return 1
  cwd="$(readlink "/proc/$watch_pid/cwd" 2>/dev/null)"
  LIVE_PGID="$(ps -o pgid= -p "$watch_pid" | tr -d ' ')"
  LIVE_WT="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "${LIVE_PGID:-}" ] && [ -n "${LIVE_WT:-}" ]
}

state_get(){ grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$STATE_FILE" | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'; }
port_busy(){ ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }

# --- health-gate helpers (shared by cutover) ---
# Extract activePlatforms (one name per line) from a health JSON blob on stdin.
# Isolate the [...] array first so the "activePlatforms" key itself is not captured.
_platforms_from_health(){ grep -oE '"activePlatforms"[[:space:]]*:[[:space:]]*\[[^]]*\]' | grep -oE '\[[^]]*\]' | grep -oE '"[^"]*"' | sed 's/^"//; s/"$//'; }
# Print the ';'-joined active platform set of the server on port $1 (empty on failure).
capture_platforms(){ curl -s --max-time 5 "http://127.0.0.1:$1/api/health" 2>/dev/null | _platforms_from_health | paste -sd';' -; }
# Return 0 if any FORBID_LOG regex is present in logfile $1.
_forbid_hit(){
  [ -n "${FORBID_LOG:-}" ] || return 1
  local IFS=';' pat
  for pat in $FORBID_LOG; do [ -n "$pat" ] && grep -Eq "$pat" "$1" 2>/dev/null && { log "  [gate] FORBID_LOG matched: /$pat/"; return 0; }; done
  return 1
}

# run_health_gate LOGFILE [MODE]
#   MODE=full  (default) apply ALL constraints (default gate + operator constraints)
#   MODE=basic apply only startup + platform parity (used when validating a rollback)
# Returns 0 if healthy, non-zero if any constraint fails or the deadline elapses.
run_health_gate(){
  local logf="$1" mode="${2:-full}" start ready h have want p pat missing
  start="$(date +%s)"

  # Phase A: startup finished (READY_MARKER), watching forbidden strings + timeout.
  ready=0
  while :; do
    _forbid_hit "$logf" && return 1
    grep -q "$READY_MARKER" "$logf" 2>/dev/null && ready=1
    [ "$ready" = 1 ] && break
    [ $(( $(date +%s) - start )) -ge "$CUTOVER_DEADLINE" ] && { log "  [gate] startup exceeded ${CUTOVER_DEADLINE}s (no '$READY_MARKER')"; return 1; }
    sleep 1
  done
  log "  [gate] startup ok ('$READY_MARKER') after $(( $(date +%s) - start ))s"

  # Phase B: health endpoint ok + platform parity.
  if [ "$SKIP_PLATFORM_PARITY" != 1 ]; then
    want="${REQUIRE_PLATFORMS:-${OLD_PLATFORMS:-}}"
    while :; do
      h="$(curl -s --max-time 5 "$HEALTH_URL" 2>/dev/null)"
      if printf '%s' "$h" | grep -qE '"status"[[:space:]]*:[[:space:]]*"ok"'; then
        have="$(printf '%s' "$h" | _platforms_from_health)"
        missing=""
        local IFS=';'
        for p in $want; do [ -n "$p" ] || continue; printf '%s\n' "$have" | grep -Fxq "$p" || missing="$missing $p"; done
        unset IFS
        [ -z "$missing" ] && { log "  [gate] health ok + platform parity (required: ${want:-<none>})"; break; }
      fi
      _forbid_hit "$logf" && return 1
      [ $(( $(date +%s) - start )) -ge "$CUTOVER_DEADLINE" ] && { log "  [gate] health/parity not reached (missing:${missing:-?})"; return 1; }
      sleep 2
    done
  fi

  [ "$mode" = basic ] && { log "  [gate] basic checks passed"; return 0; }

  # Phase C: operator REQUIRE_LOG regexes must all appear (within the deadline).
  if [ -n "$REQUIRE_LOG" ]; then
    local IFS=';'
    for pat in $REQUIRE_LOG; do
      [ -n "$pat" ] || continue
      while :; do
        grep -Eq "$pat" "$logf" 2>/dev/null && { log "  [gate] REQUIRE_LOG ok: /$pat/"; break; }
        _forbid_hit "$logf" && { unset IFS; return 1; }
        [ $(( $(date +%s) - start )) -ge "$CUTOVER_DEADLINE" ] && { log "  [gate] REQUIRE_LOG not found: /$pat/"; unset IFS; return 1; }
        sleep 2
      done
    done
    unset IFS
  fi

  # Phase D/E: operator custom command + hook (each must exit 0).
  if [ -n "$HEALTH_CMD" ]; then
    log "  [gate] running HEALTH_CMD ..."
    NEW_LOG="$logf" SERVER_URL="$HEALTH_URL" LIVE_PORT="$LIVE_PORT" bash -c "$HEALTH_CMD" || { log "  [gate] HEALTH_CMD failed"; return 1; }
  fi
  if [ -n "$HEALTH_HOOK" ] && [ -x "$HEALTH_HOOK" ]; then
    log "  [gate] running HEALTH_HOOK $HEALTH_HOOK ..."
    NEW_LOG="$logf" SERVER_URL="$HEALTH_URL" LIVE_PORT="$LIVE_PORT" "$HEALTH_HOOK" || { log "  [gate] HEALTH_HOOK failed"; return 1; }
  fi

  # Phase F: human confirmation with a timeout (rollback if not confirmed in time).
  if [ -n "$CONFIRM_CMD" ]; then
    log "  [gate] awaiting confirmation (timeout ${CONFIRM_TIMEOUT_S}s) ..."
    NEW_LOG="$logf" SERVER_URL="$HEALTH_URL" LIVE_PORT="$LIVE_PORT" \
      timeout "$CONFIRM_TIMEOUT_S" bash -c "$CONFIRM_CMD" || { log "  [gate] not confirmed within ${CONFIRM_TIMEOUT_S}s"; return 1; }
  fi

  log "  [gate] ALL CHECKS PASSED"
  return 0
}
