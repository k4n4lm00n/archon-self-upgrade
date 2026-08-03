#!/usr/bin/env bash
# Phase 3: validate the staged build. Non-destructive. Runs against the staging worktree only.
source "$(dirname "$0")/lib.sh"
[ -d "$STAGE_WT" ] || die "no staging worktree — run 02-stage.sh first"
LIVE_WT="$(state_get live_worktree)"

cd "$STAGE_WT" || die "cannot cd staging"
export PATH="$BIN_PATH_PREPEND:$PATH"

# Schema-drift guard: staging migrations must match live, or a boot could hit un-applied schema.
if [ -d migrations ] && [ -d "$LIVE_WT/migrations" ]; then
  LIVE_MIG="$(cd "$LIVE_WT" && git ls-tree --name-only HEAD migrations/ | sort)"
  NEXT_MIG="$(git ls-tree --name-only HEAD migrations/ | sort)"
  if [ "$LIVE_MIG" != "$NEXT_MIG" ]; then
    log "WARN: migration set differs between live and staging:"
    diff <(echo "$LIVE_MIG") <(echo "$NEXT_MIG") | sed 's/^/    /'
    log "WARN: verify migrations apply at startup before cutover."
  else
    log "migration set matches live (no schema drift)."
  fi
fi

[ -n "$INSTALL_CMD" ]   && { log "install ...";    eval "$INSTALL_CMD"   || die "install failed"; }
[ -n "$TYPECHECK_CMD" ] && { log "type-check ..."; eval "$TYPECHECK_CMD" || die "type-check failed"; }
[ -n "$BUILD_CMD" ]     && { log "build ...";      eval "$BUILD_CMD"     || die "build failed"; }
[ -n "$TEST_CMD" ]      && { log "tests ...";      eval "$TEST_CMD"      || die "tests failed"; }

log "VALIDATE OK — $STAGE_WT ($(git rev-parse --short HEAD))"
