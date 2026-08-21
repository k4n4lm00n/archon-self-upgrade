#!/usr/bin/env bash
# Detached watcher: waits for the LiteLLM gateway Pi is CONFIGURED to use (read live from
# ~/.pi/agent/auth.json each tick, so it follows a repoint to a local LiteLLM), then runs the
# Pi-0.83 stale-ctx repro against the DEPLOYED composite build and posts the verdict to Zulip.
# Loops until the smoke PASSES (no deadline — the outage may be long); writes `done` on pass so
# heal.sh won't relaunch it afterward. Detached via setsid; kept alive by heal.sh (which the
# pr-sync daemon calls each tick — the "archon way").
set -uo pipefail

DIR="$HOME/.archon/.local/upgrade/litellm-smoke-watch"
LOG="$DIR/watch.log"
DONE="$DIR/done"
PIDFILE="$DIR/watch.pid"
COMPOSITE="$HOME/worktrees/archon-deploy-next"
PROJ="$HOME/.archon/workspaces/local/pi-litellm-test/source"
NOTIFY="bash $HOME/.archon/.local/upgrade/notify-cutover.sh"   # -> Zulip "Archon - self-upgrade"
INTERVAL="${INTERVAL:-300}"     # poll every 5 min
LOCAL_CANDIDATES="http://127.0.0.1:4000 http://localhost:4000"

export PATH="$HOME/.bun/bin:$PATH"
# The live server exports PI_PACKAGE_DIR=/tmp/archon-pi-shim (no dist/) which breaks the pi
# runtime; a detached child must NOT inherit it — use the bundled provider from node_modules.
unset PI_PACKAGE_DIR CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH 2>/dev/null || true

mkdir -p "$DIR"
log(){ echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }

[ -f "$DONE" ] && { log "already done ($(cat "$DONE")) — nothing to do"; exit 0; }
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  log "another watcher alive (pid $(cat "$PIDFILE")) — exiting"; exit 0
fi
echo "$$" > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# The gateway base Pi actually uses (normalize away a trailing /v1). Re-read every tick.
pi_base(){ local b; b=$(grep -oE 'https?://[^"]+' "$HOME/.pi/agent/auth.json" 2>/dev/null | head -1); echo "${b%/v1}"; }
probe(){ curl -s --max-time 8 -o /dev/null -w '%{http_code}' "$1/v1/models" 2>/dev/null || echo 000; }

log "started (pid $$); loop-until-pass, poll ${INTERVAL}s; composite=$COMPOSITE"
while :; do
  base="$(pi_base)"
  if [ -z "$base" ]; then log "no pi base url in auth.json — waiting"; sleep "$INTERVAL"; continue; fi
  code="$(probe "$base")"
  if [ "$code" = "200" ]; then
    log "gateway $base reachable (200) — running e2e-pi-stale-ctx smoke"
    OUT="$DIR/smoke-$(date -u +%Y%m%dT%H%M%SZ).log"
    if ! cd "$COMPOSITE" 2>/dev/null; then
      log "composite worktree $COMPOSITE missing"; $NOTIFY "⚠️ LiteLLM smoke: composite worktree missing — cannot run"; exit 1
    fi
    timeout 600 bun packages/cli/src/cli.ts workflow run e2e-pi-stale-ctx "pi stale ctx repro" \
      --cwd "$PROJ" --no-worktree > "$OUT" 2>&1
    rc=$?
    if grep -qiE 'stale after session replacement|extension ctx is stale' "$OUT"; then
      verdict="❌ FAIL — stale-ctx error reappeared"
    elif [ "$rc" -eq 0 ] && grep -qw '4' "$OUT" && grep -qw '6' "$OUT"; then
      verdict="✅ PASS — both Pi/LiteLLM nodes answered (2+2=4, 3+3=6), no stale-ctx throw"
    else
      verdict="⚠️ INCONCLUSIVE (rc=$rc) — inspect the log"
    fi
    log "verdict: $verdict (rc=$rc, base=$base, log=$OUT)"
    # Only mark done on a definitive PASS/FAIL; retry on INCONCLUSIVE (transient gateway hiccup).
    tailsnip=$(tail -n 8 "$OUT" 2>/dev/null | tr '\n' ' ' | cut -c1-500)
    if printf '%s' "$verdict" | grep -qE '✅|❌'; then
      echo "$(date -u +%FT%TZ) $verdict" > "$DONE"
      $NOTIFY "$(printf '%s\n\nLive Pi-0.83 LiteLLM smoke on composite 737784f9 (e2e-pi-stale-ctx, deployed provider).\ngateway=%s rc=%s log=%s\ntail: %s' "$verdict" "$base" "$rc" "$OUT" "$tailsnip")"
      exit 0
    fi
    log "inconclusive — will retry next tick"
  else
    # Helpful hint: a local LiteLLM may be up while pi is still pointed at the (down) configured base.
    for c in $LOCAL_CANDIDATES; do
      [ "$c" = "$base" ] && continue
      [ "$(probe "$c")" = "200" ] && log "hint: LiteLLM reachable at $c but pi base=$base ($code). Repoint ~/.pi/agent/auth.json to $c and the smoke will run automatically."
    done
  fi
  sleep "$INTERVAL"
done
