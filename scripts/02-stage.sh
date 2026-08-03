#!/usr/bin/env bash
# Phase 2: build the target in an isolated worktree. Non-destructive to live.
# Deploys TARGET_REF on `myfork` (default: the fork's HEAD branch). Optionally replays
# `mylive`'s unmerged commits onto the target when CARRY_LIVE_COMMITS=1 (patch-id aware).
source "$(dirname "$0")/lib.sh"
[ -f "$STATE_FILE" ] || die "no state.json — run 01-snapshot.sh first"

LIVE_WT="$(state_get live_worktree)"
LIVE_SHA="$(state_get live_sha)"
cd "$LIVE_WT" || die "live worktree missing"

log "fetching $FORK_REMOTE / $UPSTREAM_REMOTE ..."
git fetch "$FORK_REMOTE" --quiet || die "fetch $FORK_REMOTE failed"
git fetch "$UPSTREAM_REMOTE" --quiet || log "WARN: fetch $UPSTREAM_REMOTE failed (continuing)"

# Resolve TARGET_REF if not provided: the fork's default (HEAD) branch.
if [ -z "$TARGET_REF" ]; then
  FORK_DEFAULT="$(git remote show "$FORK_REMOTE" 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -1)"
  FORK_DEFAULT="${FORK_DEFAULT:-main}"
  TARGET_REF="$FORK_REMOTE/$FORK_DEFAULT"
fi
git rev-parse --verify --quiet "$TARGET_REF" >/dev/null || die "TARGET_REF '$TARGET_REF' not resolvable"
TARGET_SHA="$(git rev-parse "$TARGET_REF")"
log "target to deploy: $TARGET_REF (${TARGET_SHA:0:12})"

# (Re)create the staging worktree at the target.
if git worktree list --porcelain | grep -q "$STAGE_WT"; then
  log "removing stale staging worktree $STAGE_WT"
  git worktree remove --force "$STAGE_WT" 2>/dev/null || rm -rf "$STAGE_WT"
fi
git branch -f "$STAGE_BRANCH" "$TARGET_SHA" 2>/dev/null || git branch "$STAGE_BRANCH" "$TARGET_SHA"
git worktree add "$STAGE_WT" "$STAGE_BRANCH" || die "worktree add failed"

if [ "$CARRY_LIVE_COMMITS" = 1 ]; then
  # Replay commits on mylive but not in the target (patch-id aware; duplicates dropped).
  REPLAY="$(git rev-list --reverse --cherry-pick --right-only "$TARGET_REF...$LIVE_SHA")"
  if [ -z "$REPLAY" ]; then
    log "nothing to carry — target already contains mylive's commits"
  else
    cd "$STAGE_WT" || die "cannot cd staging"
    for c in $REPLAY; do
      log "cherry-pick ${c:0:12} ..."
      if ! git cherry-pick --allow-empty "$c"; then
        git cherry-pick --abort 2>/dev/null
        die "CONFLICT carrying ${c:0:12} — staging left clean; resolve or set CARRY_LIVE_COMMITS=0"
      fi
    done
  fi
fi

cd "$STAGE_WT" || die "cannot cd staging"
log "staging ready at $STAGE_WT ($(git rev-parse --short HEAD))"
git log --oneline -6 | sed 's/^/    /'

# Non-code drift: report files that differ from live but are NOT source code, so a human
# can eyeball config/migration/workflow drift the upgrade pulls in.
log "non-code files changed vs live (config/migrations/docs/workflows):"
git diff --name-only "$LIVE_SHA" HEAD -- \
  '*.yaml' '*.yml' '*.sql' '*.md' '.env*' '*.json' '.claude/**' '.archon/**' 2>/dev/null \
  | sed 's/^/    /' | head -60 || true
