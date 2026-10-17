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

# Persistent per-host preferences. Anchored to the TOOLKIT dir (where this lib.sh lives), NOT
# UPGRADE_DIR — the workflow repoints UPGRADE_DIR at $ARTIFACTS_DIR (ephemeral per run), but a saved
# preference must survive across runs and redeploys. Managed by self-upgrade-config.sh, which writes
# soft `VAR="${VAR:-value}"` lines: sourced BEFORE the defaults below, they set a knob only when the
# environment has not already set it — so an explicit env var for a given run still wins. Kept out of
# the committed, generic workflow YAML on purpose (host preference, not shipped config).
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_CONFIG="${SELFUPGRADE_CONFIG:-$TOOLKIT_DIR/config.env}"
[ -f "$LOCAL_CONFIG" ] && source "$LOCAL_CONFIG"

# Config resolved + persisted by 00-preflight (prompt-derived TARGET_REF, host tunables), so a
# multi-process run inherits ONE resolution: the Archon workflow executes each phase in a fresh
# shell, and this is how the target chosen in preflight reaches stage/validate/smoke/cutover. It
# is the authoritative per-run snapshot (hard values), so it is sourced AFTER the local prefs: a
# later phase must honor exactly what preflight resolved (which already folded in prefs + env).
# Standalone single-shell use that passes env to each script never needs it; when the file is
# absent this is a no-op. Written by persist_config() with %q so every value round-trips via source.
RESOLVED_ENV="$UPGRADE_DIR/resolved.env"
[ -f "$RESOLVED_ENV" ] && source "$RESOLVED_ENV"

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
LIVE_PROC_COMM="${LIVE_PROC_COMM:-${DEV_CMD%% *}}"   # /proc/<pid>/comm of the real server
# Server-ONLY start command for the isolated smoke boot. On the v0.8 monorepo `bun run dev`
# expands to `bun --filter '*' dev`, which fans out to server + web + docs (a second
# orchestrator/agent) — that must NOT happen during an isolation test. Empty => auto-resolved
# by smoke_dev_cmd() to the staged package's own `dev:server` script when present, else DEV_CMD
# (older single-package layouts). Env-overridable.
SMOKE_DEV_CMD="${SMOKE_DEV_CMD:-}"
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
# Default OFF: most deployments track a fork/upstream ref with no unmerged local work, so the
# plain target is what they want. Operators who DO run local commits on top of the target (like
# this project) turn it on persistently with `self-upgrade-config.sh set carry-live-commits yes`
# (or CARRY_LIVE_COMMITS=1 for one run). When on, 02-stage replays them patch-id aware (anything
# already merged upstream is dropped), seeded from the known-good manifest below.
CARRY_LIVE_COMMITS="${CARRY_LIVE_COMMITS:-0}"
ENV_FILE="${ENV_FILE:-$HOME/.archon/.env}"   # sourced by cutover for adapter creds
NOTIFY_CMD="${NOTIFY_CMD:-}"                  # optional: `$NOTIFY_CMD "<message>"` on outcome
SCRUB_ENV_VARS="${SCRUB_ENV_VARS:-}"         # extra env var NAMES to strip for the smoke boot

# ---- Known-good manifest (shared with start-current ensure_stack + rollback watchdog) ----
# The blessed feature stack: 02-stage seeds the carry set from its sha; the cutover refreshes
# it (+ a git bundle) on health-gate SUCCESS so the rollback floor tracks each good upgrade.
MANIFEST="${MANIFEST:-$HOME/.archon/.local/known-good.json}"
KG_BUNDLE_DIR="${KG_BUNDLE_DIR:-$UPGRADE_DIR/backups}"

# Scrub CLAUDE_* so a child server is not detected as a nested Claude agent.
CLAUDE_SCRUB=(-u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH \
  -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS -u CLAUDE_CODE_SESSION_ID)

# This workflow's OWN config vars. They must NOT leak into the long-lived server we launch:
# the server would carry them, and the NEXT upgrade (a subprocess of that server) would inherit
# them — e.g. a stale REQUIRE_LOG / TARGET_REF silently changing its behavior. start_server and
# the smoke boot strip these so every server starts with a clean, config-free environment.
SELFUPGRADE_SCRUB=()
for _v in UPGRADE_DIR ARCHON_UPGRADE_DIR UPSTREAM_REMOTE UPSTREAM_URL FORK_REMOTE TARGET_REF \
  STAGE_WT STAGE_BRANCH LIVE_PROC_PATTERN LIVE_PROC_COMM DEV_CMD SMOKE_DEV_CMD INSTALL_CMD TYPECHECK_CMD BUILD_CMD TEST_CMD \
  BIN_PATH_PREPEND READY_MARKER CUTOVER_DEADLINE HEALTH_URL SKIP_PLATFORM_PARITY REQUIRE_PLATFORMS \
  REQUIRE_LOG FORBID_LOG HEALTH_CMD HEALTH_HOOK CONFIRM_CMD CONFIRM_TIMEOUT_S SCRUB_ENV_VARS \
  CUTOVER_SETTLE CARRY_LIVE_COMMITS MANIFEST KG_BUNDLE_DIR ENV_FILE NOTIFY_CMD OLD_PLATFORMS; do
  SELFUPGRADE_SCRUB+=(-u "$_v")
done; unset _v

ts(){ date -u +%H:%M:%S; }
log(){ echo "[$(ts)] $*"; }
die(){ echo "[$(ts)] FATAL: $*" >&2; exit 1; }

# Resolve TARGET_REF from the trigger prompt ($1) when it was not given explicitly, then verify
# it points at a real object. Precedence (the documented prompt UX — see README "How to run"):
#   explicit TARGET_REF env  >  the target named after "to" in the prompt  >  the fork's default
#   branch (no "to ..." at all). The target text after "to" is matched, in this order:
#     <owner>/<repo>@<branch> or <url>@<branch> (someone else's fork) · upstream/<b>, <fork>/<b>,
#     origin/<b> (explicit remote/branch) · "latest/newest/stable release" (highest semver tag) ·
#     a version tag v0.6.0 · feat|fix|chore|hotfix|release/<...> or dev|main|master (branch — fork
#     first, then upstream) · a raw commit SHA.
# A target that is NAMED but cannot be resolved is a HARD ERROR — never a silent fallback. Call
# from 00-preflight AFTER the remotes are fetched (tags included) so every ref is lookup-able.
resolve_target_ref(){
  local trigger="${1:-}" M T LOW TP RB VT BR SH SRC B URL FD t r
  if [ -z "$TARGET_REF" ]; then
    M="$trigger"
    if printf '%s' " $M " | grep -qiE '[[:space:]]to[[:space:]]'; then
      T="$(printf '%s' "$M" | sed -E 's/.*[[:space:]][Tt][Oo][[:space:]]+//')"
    else T=""; fi
    if [ -z "$T" ]; then
      FD="$(git remote show "$FORK_REMOTE" 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -1)"
      TARGET_REF="$FORK_REMOTE/${FD:-main}"
    else
      LOW="$(printf '%s' "$T" | tr 'A-Z' 'a-z')"
      TP="$(printf '%s' "$T" | grep -oE '(https?://[^ ]+|[A-Za-z0-9_.:@/-]+\.git|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@[A-Za-z0-9._/-]+' | head -1 || true)"
      RB="$(printf '%s' "$T" | grep -oE '(upstream|'"$FORK_REMOTE"'|origin)/[A-Za-z0-9._/-]+' | head -1 || true)"
      VT="$(printf '%s' "$T" | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
      BR="$(printf '%s' "$T" | grep -oE '(feat|fix|chore|hotfix|release)/[A-Za-z0-9._/-]+' | head -1 || true)"
      [ -z "$BR" ] && BR="$(printf '%s' "$T" | grep -owE 'dev|main|master' | head -1 || true)"
      SH="$(printf '%s' "$T" | grep -oiE '[0-9a-f]{7,40}' | head -1 || true)"
      if [ -n "$TP" ]; then
        SRC="${TP%@*}"; B="${TP##*@}"
        case "$SRC" in http*|git@*|*.git) URL="$SRC";; *) URL="https://github.com/$SRC";; esac
        log "fetching third-party branch '$B' from $URL ..."
        git fetch "$URL" "$B" --quiet || die "could not fetch '$B' from $URL"
        TARGET_REF="$(git rev-parse FETCH_HEAD)"
      elif [ -n "$RB" ]; then
        git rev-parse --verify --quiet "$RB" >/dev/null && TARGET_REF="$RB" || die "remote branch '$RB' not found (is it pushed/fetched?)"
      elif printf '%s' "$LOW" | grep -qE 'latest|newest|stable'; then
        TARGET_REF="$(git tag --list 'v[0-9]*' | sort -V | tail -1)"; [ -n "$TARGET_REF" ] || die "no version tags found for 'latest release'"
      elif [ -n "$VT" ]; then
        for t in "$VT" "v$VT"; do git rev-parse --verify --quiet "refs/tags/$t" >/dev/null && { TARGET_REF="$t"; break; }; done
        [ -n "$TARGET_REF" ] || die "version tag '$VT' not found among fetched tags"
      elif [ -n "$BR" ]; then
        for r in "$FORK_REMOTE/$BR" "$UPSTREAM_REMOTE/$BR"; do git rev-parse --verify --quiet "$r" >/dev/null && { TARGET_REF="$r"; break; }; done
        [ -n "$TARGET_REF" ] || die "branch '$BR' not found on $FORK_REMOTE or $UPSTREAM_REMOTE"
      elif [ -n "$SH" ]; then
        git rev-parse --verify --quiet "${SH}^{commit}" >/dev/null && TARGET_REF="$SH" || die "commit '$SH' not found (is it fetched?)"
      else
        die "could not understand the upgrade target \"$T\" — see the README 'How to run'"
      fi
    fi
  fi
  git rev-parse --verify --quiet "$TARGET_REF" >/dev/null || die "TARGET_REF '$TARGET_REF' not resolvable"
  log "target ref to deploy: $TARGET_REF ($(git rev-parse --short "$TARGET_REF"))"
}

# Persist the fully-resolved runtime config to RESOLVED_ENV so every later phase (each a fresh
# shell in the workflow) re-sources the SAME resolution — most importantly the prompt-derived
# TARGET_REF and the CARRY decision. Values are written with %q so they round-trip through
# `source` safely. The location vars (UPGRADE_DIR / ARCHON_UPGRADE_DIR) are deliberately NOT
# persisted — they bootstrap RESOLVED_ENV itself and must stay controlled by the caller.
persist_config(){
  local v
  mkdir -p "$(dirname "$RESOLVED_ENV")"
  {
    for v in UPSTREAM_REMOTE UPSTREAM_URL FORK_REMOTE TARGET_REF LIVE_PORT SMOKE_PORT \
             STAGE_WT STAGE_BRANCH LIVE_PROC_PATTERN LIVE_PROC_COMM DEV_CMD SMOKE_DEV_CMD \
             INSTALL_CMD TYPECHECK_CMD BUILD_CMD TEST_CMD BIN_PATH_PREPEND READY_MARKER \
             CUTOVER_DEADLINE HEALTH_URL SKIP_PLATFORM_PARITY REQUIRE_PLATFORMS REQUIRE_LOG \
             FORBID_LOG HEALTH_CMD HEALTH_HOOK CONFIRM_CMD CONFIRM_TIMEOUT_S SCRUB_ENV_VARS \
             CUTOVER_SETTLE CARRY_LIVE_COMMITS MANIFEST KG_BUNDLE_DIR ENV_FILE NOTIFY_CMD; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$RESOLVED_ENV"
  log "persisted resolved config -> $RESOLVED_ENV"
}

# Messenger-agnostic smoke isolation. The server loads its user-scope env from
# `getArchonEnvPath()`, which honors ARCHON_HOME, with override:true. So for the smoke boot we
# point ARCHON_HOME at a scratch dir holding a COPY of the real env file with every credential
# blanked — the server loads that (override), every adapter's presence-gate (`Boolean(env.X)`)
# is false => no adapter starts, while DB/other config still load. No HOME override (Claude
# global auth via ~/.claude still works), no file left in the worktree (nothing to leak into the
# cutover). Names no platform.
#
# Every v0.8 adapter gates on at least one credential-pattern var, so blanking them all disables
# each one: Telegram/Discord/Slack (*_BOT_TOKEN / *_APP_TOKEN), GitHub App+PAT (WEBHOOK_SECRET,
# GITHUB_TOKEN — blanking the shared WEBHOOK_SECRET forces selectGitHubAuthMode -> 'none', not a
# throw), Gitea/GitLab (*_TOKEN + *_WEBHOOK_SECRET), Zulip (ZULIP_BOT_EMAIL, ZULIP_BOT_API_KEY).
_CRED_NAME_RE='(TOKEN|SECRET|API_?KEY|WEBHOOK|PASSWORD|PASSWD|CREDENTIAL|BOT_|_BOT)'

# Resolve the server-ONLY start command for the smoke boot (see SMOKE_DEV_CMD). Honors an
# explicit SMOKE_DEV_CMD override; else uses `bun run dev:server` when the staged package.json
# defines it (the v0.8 monorepo server-only script), else falls back to DEV_CMD (older layouts
# where `bun run dev` already started only the server).
smoke_dev_cmd(){
  if [ -n "${SMOKE_DEV_CMD:-}" ]; then printf '%s' "$SMOKE_DEV_CMD"; return 0; fi
  if [ -f "$STAGE_WT/package.json" ] && grep -Eq '"dev:server"[[:space:]]*:' "$STAGE_WT/package.json"; then
    printf 'bun run dev:server'
  else
    printf '%s' "$DEV_CMD"
  fi
}

# v0.8 three-path env model defense. loadArchonEnv() loads `<cwd>/.archon/.env` (repo scope)
# with override:true AFTER the scrubbed ARCHON_HOME/.env, so a credentialed repo-scope file in
# the staging worktree would UN-blank adapters and defeat the isolation. Scrub it in place for
# the boot and restore it byte-for-byte afterward (worktree ends unchanged => nothing leaks to
# cutover). Sets REPO_ENV_BAK (empty when there was no repo-scope env); pair with restore_repo_env
# in the smoke cleanup trap.
REPO_ENV_BAK=""
scrub_repo_env(){
  local repo_env="$1/.archon/.env"
  REPO_ENV_BAK=""
  [ -f "$repo_env" ] || return 0
  REPO_ENV_BAK="$(mktemp)"; cp "$repo_env" "$REPO_ENV_BAK"
  write_scrubbed_env_file "$REPO_ENV_BAK" "$repo_env"
}
restore_repo_env(){
  [ -n "${REPO_ENV_BAK:-}" ] || return 0
  cp "$REPO_ENV_BAK" "$1/.archon/.env" 2>/dev/null || true
  rm -f "$REPO_ENV_BAK"; REPO_ENV_BAK=""
}

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

# Resolve the pid of the live server. A command line can MENTION the pattern without being
# the server — a shell running pgrep, an editor, the launcher of this very run. Anchoring
# the rollback to one of those (or, worse, stopping its process group at cutover) would hit
# the wrong tree, so require the match to actually be the server binary.
live_pid() {
  local p
  for p in $(pgrep -f "$LIVE_PROC_PATTERN" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    [ "$(cat "/proc/$p/comm" 2>/dev/null)" = "$LIVE_PROC_COMM" ] || continue
    echo "$p"; return 0
  done
  return 1
}

detect_live() {
  local watch_pid cwd
  watch_pid="$(live_pid)"
  [ -n "$watch_pid" ] || return 1
  cwd="$(readlink "/proc/$watch_pid/cwd" 2>/dev/null)"
  LIVE_PGID="$(ps -o pgid= -p "$watch_pid" | tr -d ' ')"
  LIVE_WT="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "${LIVE_PGID:-}" ] && [ -n "${LIVE_WT:-}" ]
}

state_get(){ grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$STATE_FILE" | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'; }
# Read one string field from any hand-rolled flat-JSON file ($1=file, $2=key).
json_file_get(){ [ -f "$1" ] || return 1; grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'; }
port_busy(){ ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }

# Promote a worktree to the blessed known-good: rewrite the manifest + refresh its git bundle,
# so the cold-start ensure_stack and the rollback watchdog both restore to THIS build. Called
# from the cutover on health-gate SUCCESS (a validated-good build) — never on rollback, so the
# rollback floor can only ever advance onto a build that passed the full gate. Best-effort:
# any failure here is logged, never fatal (the cutover has already succeeded by this point).
write_known_good(){ # $1 = worktree
  local wt="$1" br sha plat bnd tmp
  [ -n "$wt" ] && [ -d "$wt" ] || { log "known-good: no worktree '$wt' — skip promote"; return 0; }
  br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  [ -n "$sha" ] || { log "known-good: cannot resolve HEAD of $wt — skip promote"; return 0; }
  plat="$(capture_platforms "$LIVE_PORT")"
  mkdir -p "$KG_BUNDLE_DIR"
  bnd="$KG_BUNDLE_DIR/known-good-${sha:0:8}.bundle"
  if git -C "$wt" bundle create "$bnd.tmp" "$br" >/dev/null 2>&1 && git -C "$wt" bundle verify "$bnd.tmp" >/dev/null 2>&1; then
    mv -f "$bnd.tmp" "$bnd"
  else
    rm -f "$bnd.tmp"; log "known-good: WARN bundle create/verify failed for $wt @ ${sha:0:10}"; bnd=""
  fi
  tmp="$(mktemp)"
  cat > "$tmp" <<JSON
{
  "_comment": "Blessed known-good live Archon composition. Written by the self-upgrade cutover on health-gate success and by rollback-watch/bless-known-good.sh. Consumed by start-current-archon.sh (ensure_stack) and rollback-watch/watchd.sh.",
  "captured_utc": "$(date -u +%FT%TZ)",
  "worktree": "$wt",
  "branch": "$br",
  "sha": "$sha",
  "port": $LIVE_PORT,
  "require_platforms": "$plat",
  "dev_cmd": "$DEV_CMD",
  "bundle": "$bnd"
}
JSON
  mv -f "$tmp" "$MANIFEST" && log "known-good: promoted $wt -> ${br} @ ${sha:0:12} (manifest $MANIFEST, bundle ${bnd:-none})" \
    || log "known-good: WARN could not write manifest $MANIFEST"
}

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
