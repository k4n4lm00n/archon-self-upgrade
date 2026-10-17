---
description: Hot-upgrade the live server (archon-self-upgrade workflow), or manage its local preferences.
argument-hint: "[to <target>] | set <key> <value> | get [key] | unset <key> | reset-config"
---

# /self-upgrade

Native entry point for the **archon-self-upgrade** toolkit. It has two modes: running an upgrade,
and managing persistent per-host preferences. The toolkit scripts live at `SELFUPGRADE_SCRIPTS`
(default `$HOME/.archon/.local/upgrade`).

Arguments: `$ARGUMENTS`

## Routing

Look at the first word of the arguments:

- **`set` / `get` / `unset` / `reset-config` / `path`** → a preference operation. Run the
  deterministic engine and report its output verbatim — do NOT start an upgrade:

  ```bash
  SU="${SELFUPGRADE_SCRIPTS:-$HOME/.archon/.local/upgrade}"
  bash "$SU/self-upgrade-config.sh" $ARGUMENTS
  ```

  `reset-config` removes **all** saved preferences (deletes `config.env`), restoring the
  built-in defaults; `unset <key>` removes just one.

  Keys are kebab-case and map to the toolkit env vars (`carry-live-commits` → `CARRY_LIVE_COMMITS`,
  `cutover-deadline` → `CUTOVER_DEADLINE`, …). Boolean knobs accept `1|yes|true|on` and
  `0|no|false|off`. These write soft `VAR="${VAR:-value}"` lines into
  `$SU/config.env`, which `lib.sh` sources — so a saved preference applies to every run unless an
  explicit env var overrides it for that run. They are deliberately NOT written into the committed
  workflow YAML (a host preference is not shipped config, and it must survive redeploys).

  Examples:
  - `/self-upgrade set carry-live-commits yes` — always replay our unmerged local commits onto the target.
  - `/self-upgrade set carry-live-commits 0` — back to the default (deploy the bare target).
  - `/self-upgrade get` — show all saved preferences.
  - `/self-upgrade reset-config` — drop all local overrides, back to built-in defaults.

- **anything else** (`to <target>`, `run`, or empty) → run the upgrade. Dispatch the workflow,
  passing the arguments through as the trigger prompt so target resolution (`to dev`,
  `to the latest release`, `to alice/Archon@feat/x`, a version tag, a SHA, …) works:

  ```
  /invoke-workflow archon-self-upgrade --prompt "self upgrade $ARGUMENTS"
  ```

  (Omit `$ARGUMENTS` entirely to deploy the fork's default branch.)

## Notes

- `set`/`get`/`unset` never touch the live server — they only edit the local config file.
- Carry defaults to **off**. Turn it on persistently with `set carry-live-commits yes`; most
  deployments track a fork/upstream ref with no unmerged local work and want the bare target.
