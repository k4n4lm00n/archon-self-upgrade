# 03 — Phase reference (scripts)

The [`scripts/`](../scripts/) directory is the manual/standalone form of the workflow: the
messenger-agnostic, two-remote (`upstream` + `myfork`) toolkit that mirrors
[`../archon-self-upgrade.yaml`](../archon-self-upgrade.yaml). All scripts source `lib.sh` for
shared, env-overridable config. Runtime state lives under `ARCHON_UPGRADE_DIR`
(default `~/.archon/.local/upgrade/`): `state.json`, `cutover-status.json`, `logs/`.

## `lib.sh` — shared config + helpers

Defines the remotes (`UPSTREAM_REMOTE`/`UPSTREAM_URL`, `FORK_REMOTE`), the deploy target
(`TARGET_REF`), staging worktree/branch, ports, the command set (`DEV_CMD`, `INSTALL_CMD`,
`TYPECHECK_CMD`, `BUILD_CMD`, `TEST_CMD`, `BIN_PATH_PREPEND`), the health-gate knobs
(`READY_MARKER`, `CUTOVER_DEADLINE`, `HEALTH_URL`, platform-parity + operator constraints),
and the cutover settle/notify knobs. It also defines `run_health_gate` (the shared gate) and
`capture_platforms`. See
[06-workflow.md](06-workflow.md#configuration-env-vars-with-defaults) for the full env table
and [the rollback-constraints section](06-workflow.md#rollback-constraints-the-health-gate)
(the scripts and the workflow share the same variables and gate logic).

Helpers: `live_pid` (the pid of the live server: a `LIVE_PROC_PATTERN` match whose
`/proc/<pid>/comm` is `LIVE_PROC_COMM`, so a command line that merely *mentions* the pattern
cannot be mistaken for the server), `detect_live` (its **pgid** + worktree),
`write_scrubbed_env_file` (writes a credential-blanked copy of the env file for the smoke
boot's `ARCHON_HOME`, blanking every name matching the credential pattern plus `SCRUB_ENV_VARS`),
`state_get`, `port_busy`,
`log`/`die`, and the fixed `CLAUDE_SCRUB` array.

## `00-preflight.sh` — prerequisites

Non-destructive. Ensures the **`upstream`** remote (adds it from `UPSTREAM_URL` if missing)
and the **`myfork`** remote — **forking `upstream` via `gh repo fork` if `myfork` is absent**
(needs an authenticated `gh`). Fetches both remotes.

## `01-snapshot.sh` — capture the rollback anchor

Non-destructive. Runs `detect_live`, then writes `state.json` with the live (`mylive`)
worktree, branch, SHA, pgid, and the staging target. This is the anchor every later phase
(and rollback) relies on. Fails if no live server is running.

## `02-stage.sh` — build the target worktree

Non-destructive to live. Fetches the remotes; resolves `TARGET_REF` (defaults to the fork's
HEAD branch); (re)creates the staging worktree at that ref. With `CARRY_LIVE_COMMITS=1` it
replays `mylive`'s unmerged commits onto the target (patch-id aware; conflicts abort and
leave staging clean). Reports non-code drift (yaml/sql/md/env/json/`.claude`/`.archon`) vs
live so a human can eyeball config/migration changes the upgrade pulls in.

## `03-validate.sh` — validate the staged build

Non-destructive; staging only. Guards that the **migration set matches live** (warns on
drift), then runs `INSTALL_CMD` → `TYPECHECK_CMD` → `BUILD_CMD` → `TEST_CMD` (each skipped if
its variable is empty). Any failure aborts before anything touches production.

## `04-smoke.sh` — isolated boot test

Boots the staged build on `SMOKE_PORT` under a **scrubbed `ARCHON_HOME`** (a credential-blanked
copy of the env file, so every adapter's presence-gate is false) plus `CLAUDE_SCRUB`, via
`setsid` so the whole group can be torn down.
Success = `READY_MARKER` in the log within 120s **and** an HTTP response. Always kills the
server on exit. Because credentials are blanked (via the scrubbed `ARCHON_HOME`), the staged build connects to no external service
during this test.

## `05-cutover.sh` — the cutover (destructive, self-healing)

**Must be launched detached** because it kills the process group it runs in:

```bash
setsid bash scripts/05-cutover.sh </dev/null >"$ARCHON_UPGRADE_DIR/logs/cutover.log" 2>&1 &
```

Sequence: source `ENV_FILE` for adapter creds → settle `CUTOVER_SETTLE`s → stop the old
group(s) (re-detects a since-restarted server so it is never orphaned) → start the new build
on `LIVE_PORT` → `run_health_gate "$NEW_LOG" full` (default parity gate + all operator
constraints).
- Gate passes → `success` (exit 0).
- Gate fails → **roll back**: kill new, restart the untouched old worktree, re-check with
  `run_health_gate "$OLD_LOG" basic` (default gate only) → `rolled_back` (exit 2), or `FAILED`
  (exit 3, manual) if rollback is also unhealthy.

Every transition is written to `cutover-status.json`; on a terminal state `NOTIFY_CMD` (if
set) is called so the outcome reaches the originating channel.

### Tunables

See the [config table](06-workflow.md#configuration-env-vars-with-defaults) and the
[rollback-constraints section](06-workflow.md#rollback-constraints-the-health-gate) in
06-workflow.md. Most-used: `TARGET_REF`, `CARRY_LIVE_COMMITS`, `CUTOVER_DEADLINE`,
`REQUIRE_LOG`/`FORBID_LOG`, `HEALTH_CMD`/`HEALTH_HOOK`, `CONFIRM_CMD`, `NOTIFY_CMD`.
