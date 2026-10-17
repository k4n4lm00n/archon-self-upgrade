#!/usr/bin/env bash
# self-upgrade-config.sh — manage PERSISTENT per-host preferences for the self-upgrade toolkit.
#
# Preferences are written as soft `VAR="${VAR:-value}"` lines into a host-local config file that
# lib.sh sources before its built-in defaults. So a saved preference applies to every run UNLESS
# the same variable is set explicitly in the environment for that run (explicit env always wins).
# They live OUTSIDE the committed, generic workflow YAML — a host preference is not shipped config,
# and keeping it here means it survives redeploys that overwrite the scripts and the YAML.
#
# Usage:
#   self-upgrade-config.sh set   <key> <value>   # e.g. set carry-live-commits yes
#   self-upgrade-config.sh get   [<key>]         # print one or all saved preferences
#   self-upgrade-config.sh unset <key>           # remove a single saved preference
#   self-upgrade-config.sh reset                 # remove ALL local overrides (delete the file)
#   self-upgrade-config.sh path                  # print the config file path
#
# Keys are kebab-case and map to the lib.sh env vars: carry-live-commits -> CARRY_LIVE_COMMITS,
# cutover-deadline -> CUTOVER_DEADLINE, target-ref -> TARGET_REF, etc. Boolean knobs accept
# 1|yes|true|on and 0|no|false|off (stored as 1/0).
set -uo pipefail

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SELFUPGRADE_CONFIG:-$TOOLKIT_DIR/config.env}"

HEADER1='# self-upgrade local preferences — sourced by lib.sh as soft ${VAR:-value} defaults.'
HEADER2='# Managed by self-upgrade-config.sh (set/unset); an explicit env var still overrides these.'

# The config vars lib.sh understands — validation whitelist (mirrors persist_config's list).
KNOWN_VARS=" UPSTREAM_REMOTE UPSTREAM_URL FORK_REMOTE TARGET_REF LIVE_PORT SMOKE_PORT STAGE_WT \
STAGE_BRANCH LIVE_PROC_PATTERN LIVE_PROC_COMM DEV_CMD SMOKE_DEV_CMD INSTALL_CMD TYPECHECK_CMD \
BUILD_CMD TEST_CMD BIN_PATH_PREPEND READY_MARKER CUTOVER_DEADLINE HEALTH_URL SKIP_PLATFORM_PARITY \
REQUIRE_PLATFORMS REQUIRE_LOG FORBID_LOG HEALTH_CMD HEALTH_HOOK CONFIRM_CMD CONFIRM_TIMEOUT_S \
SCRUB_ENV_VARS CUTOVER_SETTLE CARRY_LIVE_COMMITS MANIFEST KG_BUNDLE_DIR ENV_FILE NOTIFY_CMD "
# Vars whose values are booleans (normalized to 1/0).
BOOL_VARS=" CARRY_LIVE_COMMITS SKIP_PLATFORM_PARITY "

usage(){
  cat >&2 <<EOF
usage: self-upgrade-config.sh <set|get|unset|reset|path> [key] [value]
  set <key> <value>   save a preference (kebab-case key, e.g. carry-live-commits)
  get [key]           print one or all saved preferences
  unset <key>         remove a single saved preference
  reset               remove ALL local overrides (delete the config file)
  path                print the config file path
keys map to env vars (carry-live-commits -> CARRY_LIVE_COMMITS); booleans accept 1|yes|true|on / 0|no|false|off.
config file: $CONFIG
EOF
  exit 2
}

key_to_var(){ printf '%s' "$1" | tr 'a-z-' 'A-Z_'; }
is_known(){ case "$KNOWN_VARS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
is_bool(){ case "$BOOL_VARS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

normalize_value(){ # $1=var  $2=raw  -> stdout normalized value (exit 1 on bad bool)
  local var="$1" raw="$2"
  if is_bool "$var"; then
    case "$(printf '%s' "$raw" | tr 'A-Z' 'a-z')" in
      1|yes|true|on)  printf '1' ;;
      0|no|false|off) printf '0' ;;
      *) echo "error: '$var' is boolean — use 1|yes|true|on or 0|no|false|off (got '$raw')" >&2; return 1 ;;
    esac
  else
    printf '%s' "$raw"
  fi
}

# Rewrite CONFIG = header + every existing soft-default line EXCEPT $1, then (optionally) append
# the new line $2. Keeps the file canonical and free of duplicates.
rewrite(){ # $1=var to drop  $2=new line (optional)
  local drop="$1" add="${2:-}" tmp; tmp="$(mktemp)"
  {
    printf '%s\n%s\n' "$HEADER1" "$HEADER2"
    [ -f "$CONFIG" ] && grep -E '^[A-Za-z_][A-Za-z0-9_]*="\$\{' "$CONFIG" | grep -vE "^${drop}=" || true
    [ -n "$add" ] && printf '%s\n' "$add"
  } > "$tmp"
  mkdir -p "$(dirname "$CONFIG")"
  mv "$tmp" "$CONFIG"
}

cmd_set(){
  [ $# -ge 2 ] || usage
  local key="$1" raw="$2" var val
  var="$(key_to_var "$key")"
  is_known "$var" || { echo "error: unknown key '$key' (-> $var). See 'get' for valid keys." >&2; exit 1; }
  val="$(normalize_value "$var" "$raw")" || exit 1
  rewrite "$var" "$(printf '%s="${%s:-%s}"' "$var" "$var" "$val")"
  echo "set $key = $val   ($CONFIG)"
}

cmd_get(){
  [ -f "$CONFIG" ] || { echo "(no saved preferences: $CONFIG)"; return 0; }
  if [ $# -eq 0 ]; then
    grep -E '^[A-Za-z_][A-Za-z0-9_]*="\$\{' "$CONFIG" || echo "(no saved preferences)"
    return 0
  fi
  local var; var="$(key_to_var "$1")"
  grep -E "^${var}=" "$CONFIG" || echo "(unset: $1)"
}

cmd_unset(){
  [ $# -ge 1 ] || usage
  local var; var="$(key_to_var "$1")"
  [ -f "$CONFIG" ] || { echo "(nothing to unset: $CONFIG)"; return 0; }
  rewrite "$var"
  echo "unset $1   ($CONFIG)"
}

cmd_reset(){
  if [ -f "$CONFIG" ]; then
    rm -f "$CONFIG"
    echo "reset — removed all local preferences ($CONFIG)"
  else
    echo "(no local preferences to reset: $CONFIG)"
  fi
}

case "${1:-}" in
  set)               shift; cmd_set "$@" ;;
  get)               shift; cmd_get "$@" ;;
  unset)             shift; cmd_unset "$@" ;;
  reset|reset-config) cmd_reset ;;
  path)              echo "$CONFIG" ;;
  *)                 usage ;;
esac
