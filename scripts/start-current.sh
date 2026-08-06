#!/usr/bin/env bash
# start-current.sh — cold-start the build that was serving last.
#
# The upgrade phases (01..05) SWAP a running server. This script does the other half:
# after a host or container restart there is nothing to swap, so it works out which
# worktree was serving last and boots that one — with the same launch semantics as
# `05-cutover.sh:start_server` and a subset of the same gate as `lib.sh:run_health_gate`.
#
# Deliberately SELF-CONTAINED (it does not source lib.sh): it is meant to be copied to a
# fixed path and used as a container/service entrypoint, where a toolkit checkout may not
# exist yet. Defaults mirror lib.sh; every value is env-overridable by the same names.
#
#   start-current.sh                 detect + start + gate, then exit
#   start-current.sh --detect-only   print what it would start, change nothing
#   start-current.sh --entrypoint    detect + start + gate, then stay in the foreground
#                                    and forward SIGTERM/SIGINT to the server group
#
# Detection order — first hit wins, it never guesses:
#   1. a server already running          -> adopt it (idempotent, safe to re-run)
#   2. $POINTER                          -> written on every healthy start by this script
#   3. newest cutover-status.json under $ARCHON_UPGRADE_DIRS
#      `success` / `rolled_back` name the serving worktree in `detail`; any other phase
#      falls back to `live_worktree` in the sibling state.json
#
# Exit: 0 healthy (or already running) | 1 nothing detected / target unusable
#       2 started but did not pass the gate (the server is LEFT RUNNING for inspection)
set -uo pipefail

HOME="${HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}"
ARCHON_HOME="${ARCHON_HOME:-$HOME/.archon}"
STATE_DIR="${STATE_DIR:-$ARCHON_HOME/.local}"

# ---- Where to look for the record of the last cutover (space-separated globs) ----
ARCHON_UPGRADE_DIRS="${ARCHON_UPGRADE_DIRS:-$STATE_DIR/upgrade-runs/* $STATE_DIR/upgrade}"
POINTER="${POINTER:-$STATE_DIR/current-live.json}"

# ---- Launch (same names/defaults as lib.sh) ----
LIVE_PORT="${LIVE_PORT:-3090}"
LIVE_PROC_PATTERN="${LIVE_PROC_PATTERN:-bun --watch src/index.ts}"
DEV_CMD="${DEV_CMD:-bun run dev}"
LIVE_PROC_COMM="${LIVE_PROC_COMM:-${DEV_CMD%% *}}"   # /proc/<pid>/comm of the real server
BIN_PATH_PREPEND="${BIN_PATH_PREPEND:-$HOME/.bun/bin}"
SERVER_LOG="${SERVER_LOG:-$STATE_DIR/logs/server-current.log}"

# ---- Startup gate (a subset of the cutover gate: no parity capture, no rollback) ----
READY_MARKER="${READY_MARKER:-server_ready}"
MESSENGER_READY_MARKER="${MESSENGER_READY_MARKER:-}"  # e.g. the adapter's "bot started" line
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:$LIVE_PORT/api/health}"
REQUIRE_PLATFORMS="${REQUIRE_PLATFORMS:-}"            # ';'-list that must be active
START_DEADLINE="${START_DEADLINE:-150}"
POST_START_CMD="${POST_START_CMD:-}"                  # optional; run once, after healthy

# Scrub CLAUDE_* so the server is not detected as a nested agent (see lib.sh). Swept from
# the live environment rather than hardcoded: a cold start is often driven from an agent
# session, and the set of markers it exports grows over time (CLAUDECODE,
# CLAUDE_CODE_ENTRYPOINT/EXECPATH/SESSION_ID/CHILD_SESSION/EXPERIMENTAL_AGENT_TEAMS, ...).
CLAUDE_SCRUB=()
while IFS= read -r _v; do CLAUDE_SCRUB+=(-u "$_v"); done \
  < <(compgen -e | grep -E '^(CLAUDECODE|CLAUDE_CODE_)' || true)

# This script's OWN config must not leak either: the server would carry it, and anything it
# later spawns (an upgrade run, for one) would inherit a stale marker or platform list.
SELF_SCRUB=()
for _v in STATE_DIR ARCHON_UPGRADE_DIRS POINTER LIVE_PORT LIVE_PROC_PATTERN DEV_CMD \
  BIN_PATH_PREPEND SERVER_LOG READY_MARKER MESSENGER_READY_MARKER HEALTH_URL \
  REQUIRE_PLATFORMS START_DEADLINE POST_START_CMD; do
  SELF_SCRUB+=(-u "$_v")
done; unset _v

MODE=start
case "${1:-}" in
  --detect-only|-n) MODE=detect ;;
  --entrypoint)     MODE=entrypoint ;;
  --help|-h)        sed -n '2,26p' "$0"; exit 0 ;;
  "")               ;;
  *)                echo "unknown argument: $1 (try --help)" >&2; exit 1 ;;
esac

ts(){ date -u +%H:%M:%S; }
log(){ echo "[$(ts)] $*"; }
die(){ echo "[$(ts)] FATAL: $*" >&2; exit 1; }

# Read one string field out of the toolkit's hand-rolled JSON files.
json_get(){ # $1 = file ; $2 = key
  [ -f "$1" ] || return 1
  grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
}

git_top(){ git -C "$1" rev-parse --show-toplevel 2>/dev/null; }
describe(){ # $1 = worktree
  printf '%s @ %s (%s)' "$1" \
    "$(git -C "$1" rev-parse --short HEAD 2>/dev/null || echo '?')" \
    "$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
}

# --- 1. already running? -------------------------------------------------------------
# A command line can MENTION the pattern without being the server — a shell running pgrep,
# an editor, this script's own launcher. Matching one of those and "adopting" it would report
# a live server that isn't there (and, in tools that kill by pgid, kill the wrong group).
# So require the match to actually be the server binary.
RUNNING_PID=""
for _p in $(pgrep -f "$LIVE_PROC_PATTERN" 2>/dev/null); do
  [ "$_p" = "$$" ] && continue
  [ "$(cat "/proc/$_p/comm" 2>/dev/null)" = "$LIVE_PROC_COMM" ] || continue
  RUNNING_PID="$_p"; break
done
if [ -n "$RUNNING_PID" ]; then
  RUNNING_WT="$(git_top "$(readlink "/proc/$RUNNING_PID/cwd" 2>/dev/null)")"
  RUNNING_PGID="$(ps -o pgid= -p "$RUNNING_PID" 2>/dev/null | tr -d ' ')"
  log "already serving: $(describe "${RUNNING_WT:-?}") (pgid ${RUNNING_PGID:-?})"
  [ "$MODE" = detect ] && exit 0
  PGID="$RUNNING_PGID"; TARGET="$RUNNING_WT"
  ADOPTED=1
fi

if [ -z "${ADOPTED:-}" ]; then
  # A foreign process on the port is a hard stop — never boot a second server onto it.
  if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    die "$HEALTH_URL answers but no '$LIVE_PROC_PATTERN' process was found — refusing to start a second server"
  fi

  # --- 2. pointer ---------------------------------------------------------------------
  TARGET="$(json_get "$POINTER" worktree)"
  [ -n "$TARGET" ] && SOURCE="pointer $POINTER"

  # --- 3. newest cutover-status.json --------------------------------------------------
  if [ -z "$TARGET" ]; then
    NEWEST=""
    # shellcheck disable=SC2086 # ARCHON_UPGRADE_DIRS is a deliberate glob list
    for d in $ARCHON_UPGRADE_DIRS; do
      [ -f "$d/cutover-status.json" ] || continue
      u="$(json_get "$d/cutover-status.json" utc)"
      NEWEST="$(printf '%s\t%s\n%s' "${u:-0000}" "$d" "$NEWEST" | sort -r | head -1)"
    done
    RUN_DIR="${NEWEST#*$'\t'}"
    if [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ]; then
      PHASE="$(json_get "$RUN_DIR/cutover-status.json" phase)"
      case "$PHASE" in
        success|rolled_back)
          # both details read "... from <worktree> (pgid N)"
          TARGET="$(json_get "$RUN_DIR/cutover-status.json" detail | sed -nE 's|.* from (/[^ ]+).*|\1|p')" ;;
        *)
          TARGET="$(json_get "$RUN_DIR/state.json" live_worktree)"
          [ -n "$TARGET" ] && log "WARN: last cutover ended '$PHASE'; falling back to the pre-cutover build" ;;
      esac
      [ -n "$TARGET" ] && SOURCE="$RUN_DIR/cutover-status.json (phase=$PHASE)"
    fi
  fi

  [ -n "$TARGET" ] || die "could not detect the last live build (looked at $POINTER and $ARCHON_UPGRADE_DIRS) — start it by hand once, or set POINTER"

  # --- validate before touching anything ----------------------------------------------
  [ -d "$TARGET" ]                  || die "detected worktree does not exist: $TARGET (source: $SOURCE)"
  [ "$(git_top "$TARGET")" = "$TARGET" ] || die "not a git worktree root: $TARGET (source: $SOURCE)"
  [ -d "$TARGET/node_modules" ]     || die "no node_modules in $TARGET — run the install step there first"

  log "detected: $(describe "$TARGET")"
  log "  source: $SOURCE"
  [ "$MODE" = detect ] && exit 0

  # --- start ---------------------------------------------------------------------------
  mkdir -p "$(dirname "$SERVER_LOG")" "$(dirname "$POINTER")"
  [ -f "$SERVER_LOG" ] && mv -f "$SERVER_LOG" "$SERVER_LOG.prev"

  PGID="$( cd "$TARGET" || exit 1
    setsid env "${CLAUDE_SCRUB[@]}" "${SELF_SCRUB[@]}" ARCHON_SUPPRESS_NESTED_CLAUDE_WARNING=1 \
      PATH="$BIN_PATH_PREPEND:$PATH" PORT="$LIVE_PORT" \
      $DEV_CMD </dev/null >"$SERVER_LOG" 2>&1 &
    echo "$!" )"
  [ -n "$PGID" ] || die "failed to launch $DEV_CMD from $TARGET"
  log "launched (pgid $PGID), log: $SERVER_LOG"

  # --- gate -----------------------------------------------------------------------------
  ok=0
  for i in $(seq 1 "$START_DEADLINE"); do
    if grep -q "$READY_MARKER" "$SERVER_LOG" 2>/dev/null; then
      if [ -z "$MESSENGER_READY_MARKER" ] || grep -q "$MESSENGER_READY_MARKER" "$SERVER_LOG" 2>/dev/null; then
        log "  [gate] startup ok ('$READY_MARKER'${MESSENGER_READY_MARKER:+ + '$MESSENGER_READY_MARKER'}) after ${i}s"
        ok=1; break
      fi
    fi
    kill -0 -"$PGID" 2>/dev/null || { log "  [gate] the server group died during startup"; break; }
    sleep 1
  done
  [ "$ok" = 1 ] || { log "==== NOT healthy in ${START_DEADLINE}s — see $SERVER_LOG ===="; exit 2; }

  HEALTH="$(curl -fsS --max-time 10 "$HEALTH_URL" 2>/dev/null)"
  case "$HEALTH" in
    *'"status":"ok"'*) : ;;
    *) log "  [gate] $HEALTH_URL did not report status:ok"; exit 2 ;;
  esac
  # Isolate the [...] array first so the "activePlatforms" key itself is not captured
  # (same extraction as lib.sh:_platforms_from_health).
  PLATFORMS="$(printf '%s' "$HEALTH" \
    | grep -oE '"activePlatforms"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
    | grep -oE '\[[^]]*\]' | grep -oE '"[^"]*"' | sed 's/^"//; s/"$//' | paste -sd';' -)"
  if [ -n "$REQUIRE_PLATFORMS" ]; then
    missing=""
    IFS=';' read -ra want <<< "$REQUIRE_PLATFORMS"
    for p in "${want[@]}"; do
      [ -z "$p" ] && continue
      case ";$PLATFORMS;" in *";$p;"*) : ;; *) missing="$missing $p" ;; esac
    done
    [ -z "$missing" ] || { log "  [gate] missing platform(s):$missing (active: ${PLATFORMS:-none})"; exit 2; }
  fi
  log "  [gate] health ok (active: ${PLATFORMS:-none})"

  printf '{"worktree":"%s","branch":"%s","sha":"%s","pgid":"%s","port":"%s","platforms":"%s","started_utc":"%s"}\n' \
    "$TARGET" \
    "$(git -C "$TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
    "$(git -C "$TARGET" rev-parse HEAD 2>/dev/null)" \
    "$PGID" "$LIVE_PORT" "$PLATFORMS" "$(date -u +%FT%TZ)" > "$POINTER"

  log "==== SERVING from $TARGET on :$LIVE_PORT (pgid $PGID) ===="
  [ -n "$POST_START_CMD" ] && { log "post-start: $POST_START_CMD"; eval "$POST_START_CMD" || log "WARN: POST_START_CMD exited non-zero"; }
fi

[ "$MODE" = entrypoint ] || exit 0

# --- entrypoint mode: hold the foreground, pass signals down to the server group -------
term_handler(){
  log "signal received — stopping server group $PGID"
  kill -TERM -"$PGID" 2>/dev/null
  for _ in $(seq 1 15); do kill -0 -"$PGID" 2>/dev/null || break; sleep 1; done
  kill -KILL -"$PGID" 2>/dev/null
  exit 0
}
trap term_handler TERM INT
log "entrypoint mode: watching pgid $PGID"
while kill -0 -"$PGID" 2>/dev/null; do sleep 5 & wait $!; done
log "server group $PGID exited"
exit 0
