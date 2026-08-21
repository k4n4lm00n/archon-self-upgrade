#!/usr/bin/env bash
# Keep the LiteLLM smoke watcher alive — the "archon way" (same self-heal pattern as the
# pr-sync daemon's heal.sh). Idempotent + fast: called every tick by the pr-sync daemon AND
# runnable by hand on any session. No-op once the smoke has passed (`done` marker) or while the
# watcher is alive; otherwise relaunches it detached (setsid → survives session/turn boundaries).
set -uo pipefail
DIR="$HOME/.archon/.local/upgrade/litellm-smoke-watch"
DONE="$DIR/done"
PIDFILE="$DIR/watch.pid"
WATCH="$DIR/watch.sh"

if [ -f "$DONE" ]; then echo "smoke already done: $(cat "$DONE")"; exit 0; fi
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  echo "watcher alive (pid $(cat "$PIDFILE"))"; exit 0
fi
[ -x "$WATCH" ] || { echo "watch.sh missing at $WATCH"; exit 1; }
rm -f "$PIDFILE"
setsid bash "$WATCH" </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
sleep 1
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  echo "relaunched watcher (pid $(cat "$PIDFILE"))"
else
  echo "relaunch attempted (pidfile not yet written)"
fi
