#!/usr/bin/env bash
# Phase 0: prerequisites. Ensure the `upstream` and `myfork` git remotes exist; fork
# `upstream` to create `myfork` if that remote is missing. Non-destructive to the live server.
# Run from inside the target repo (or any worktree of it).
source "$(dirname "$0")/lib.sh"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository (cwd=$(pwd))"

# ---- upstream remote ----
if git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  log "upstream remote '$UPSTREAM_REMOTE' present: $(git remote get-url "$UPSTREAM_REMOTE")"
else
  [ -n "$UPSTREAM_URL" ] || die "no '$UPSTREAM_REMOTE' remote and UPSTREAM_URL unset"
  log "adding upstream remote '$UPSTREAM_REMOTE' -> $UPSTREAM_URL"
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL" || die "failed to add upstream remote"
fi
UP_SLUG="$(git remote get-url "$UPSTREAM_REMOTE" | sed -E 's#^.*[:/]([^/]+/[^/]+)$#\1#; s#\.git$##')"

# ---- myfork remote (create by forking upstream if missing) ----
if git remote get-url "$FORK_REMOTE" >/dev/null 2>&1; then
  log "fork remote '$FORK_REMOTE' present: $(git remote get-url "$FORK_REMOTE")"
else
  command -v gh >/dev/null 2>&1 || die "'$FORK_REMOTE' remote missing and gh CLI not found to create it"
  gh auth status >/dev/null 2>&1 || die "'$FORK_REMOTE' missing and gh not authenticated (connect GitHub)"
  log "fork remote '$FORK_REMOTE' missing — forking $UP_SLUG ..."
  gh repo fork "$UP_SLUG" --remote --remote-name "$FORK_REMOTE" --clone=false || die "gh repo fork failed"
  git remote get-url "$FORK_REMOTE" >/dev/null 2>&1 || die "fork created but remote '$FORK_REMOTE' not set"
fi

log "fetching remotes ..."
git fetch "$FORK_REMOTE" --quiet || die "fetch $FORK_REMOTE failed"
git fetch "$UPSTREAM_REMOTE" --quiet || log "WARN: fetch $UPSTREAM_REMOTE failed (continuing)"

log "preflight OK — remotes ready. TARGET_REF ${TARGET_REF:-<will default to the fork HEAD branch in 02-stage>}"
