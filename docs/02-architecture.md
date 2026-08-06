# 02 — Architecture

## The phases

Each phase is a standalone script sourcing shared config from `lib.sh`. State flows
through `state.json`, written by phase 01 and read by the rest.

```
┌────────────┐  ┌────────────┐  ┌──────────┐  ┌─────────────┐  ┌──────────┐  ┌─────────────┐
│00-preflight│─▶│01-snapshot │─▶│ 02-stage │─▶│ 03-validate │─▶│ 04-smoke │─▶│ 05-cutover  │
└────────────┘  └────────────┘  └──────────┘  └─────────────┘  └──────────┘  └─────────────┘
 ensure          writes           builds         install/         isolated       destructive,
 upstream+       state.json       staging @      typecheck/       boot on        self-healing
 myfork (fork    (rollback        TARGET_REF     build/test       :3091, no      (see state
 if missing)     anchor)                                          adapters      machine below)
     └──────────────────── non-destructive to live ────────────────────┘        └── prod ──┘
```

## State machine (05-cutover)

The cutover is the only stateful, destructive step. It records progress to
`cutover-status.json` at each transition so an external observer (or the agent, after
its own server restarts) can tell what happened.

```
starting ──settle CUTOVER_SETTLE s──▶ stopping (old pgid[s])
   │
   ▼
starting_new ──▶ run_health_gate(new, full)
   │                     │
   │  healthy            │ NOT healthy
   ▼                     ▼
success              rolling_back ──▶ start old worktree ──▶ run_health_gate(old, basic)
                                              │                    │
                                              │ healthy            │ NOT healthy
                                              ▼                    ▼
                                          rolled_back           FAILED
                                        (exit 2, link back)  (exit 3, manual)
```

Exit codes: `0` success · `2` rolled back cleanly · `3` rollback also failed
(manual intervention). Any observer should treat `2` as "upgrade aborted, service
intact" and `3` as a page.

## Why the cutover must be detached

`lib.sh:detect_live()` finds the live server by its `LIVE_PROC_PATTERN` (default
`bun --watch src/index.ts`), confirms the match really is the server binary
(`/proc/<pid>/comm` = `LIVE_PROC_COMM`, so a shell whose command line mentions the pattern
is not mistaken for it), and resolves its **process group id** (`pgid`). The cutover stops the whole
group with `kill -TERM -$pgid` — that group includes the shell the launching agent is
running in. Therefore `05-cutover.sh` must be launched as:

```bash
setsid bash 05-cutover.sh </dev/null >logs/cutover.log 2>&1 &
```

`setsid` puts the cutover in its **own** session/group so it survives the death of the
group it is about to kill. `CUTOVER_SETTLE` (default 45s) gives the agent time to
flush its chat reply before that happens.

## Rollback guarantee

Because 02-stage builds into a *separate* worktree and never rewrites the live one,
rollback needs no un-doing: the cutover simply re-runs `DEV_CMD` from the original
worktree recorded in `state.json`. Once the restored build passes the default gate
(startup + platform parity), the service is back and the upgrade is declared aborted (exit 2).

## Health gate

The cutover doesn't just check "is the server up" — it runs the new build through a **health
gate** (`run_health_gate` in `lib.sh`; mirrored inline in the workflow's cutover node). The
default, generic gate is:

1. `READY_MARKER` appears in the new server log (startup finished), within `CUTOVER_DEADLINE`;
2. `HEALTH_URL` reports `status: ok` **and** `activePlatforms ⊇` the set the old server had
   (**platform parity**) — an adapter only joins that set once its `start()` succeeds, so any
   integration that fails to come back trips a rollback.

Operators layer their own rollback constraints on top (`REQUIRE_LOG` / `FORBID_LOG`,
`CUTOVER_DEADLINE`, `HEALTH_CMD` / `HEALTH_HOOK`, and a human `CONFIRM_CMD` with a timeout).
Any failing check → rollback. See
[06-workflow.md](06-workflow.md#rollback-constraints-the-health-gate) for the full model and
examples. The rollback path re-validates the restored old build with the **default gate only**.

## Environment scrubbing & smoke isolation

- `CLAUDE_SCRUB` — unsets `CLAUDECODE`, `CLAUDE_CODE_*` so the child server does not
  detect itself as a nested Claude agent. Applied on **every** server launch.
- **Smoke isolation via `ARCHON_HOME`.** The server self-loads its env from
  `getArchonEnvPath()` (which honors `ARCHON_HOME`) with `override: true` — so stripping the
  *process* env can't isolate it (the reload wins). Instead, `04-smoke` writes a
  credential-blanked *copy* of the env file (`write_scrubbed_env_file`, blanking every
  name matching the credential pattern plus `SCRUB_ENV_VARS`) into a scratch dir and boots
  with `ARCHON_HOME` pointing there. Each adapter gates on `Boolean(process.env.<cred>)`, so
  blank creds ⇒ no adapter starts, while DB/other config still load. No `HOME` override
  (Claude global auth keeps working); the scratch dir is removed on exit. Names no platform.

  *(This was found the hard way during the live dry run — env-var stripping and a repo-scope
  `.env` both failed because the server force-reloads its env file; see docs/05.)*

## Host settings (env-overridable defaults)

All of these are env vars with defaults in `lib.sh` — nothing is hardcoded to a platform.

| Setting | Var(s) | Default |
|---------|--------|---------|
| Upgrade target | `TARGET_REF` | the fork's HEAD branch |
| Remotes | `UPSTREAM_REMOTE`/`UPSTREAM_URL`, `FORK_REMOTE` | `upstream` / `coleam00/Archon`, `myfork` |
| Ports | `LIVE_PORT` / `SMOKE_PORT` | `3090` / `3091` |
| Live process match | `LIVE_PROC_PATTERN` + `LIVE_PROC_COMM` | `bun --watch src/index.ts` + first word of `DEV_CMD` |
| Toolchain PATH | `BIN_PATH_PREPEND` | `~/.bun/bin` |
| Health gate | `CUTOVER_DEADLINE`, `HEALTH_URL`, `SKIP_PLATFORM_PARITY`, `REQUIRE_PLATFORMS`, `REQUIRE_LOG`, `FORBID_LOG`, `HEALTH_CMD`, `HEALTH_HOOK`, `CONFIRM_CMD`, `CONFIRM_TIMEOUT_S` | parity by default; see [06](06-workflow.md#rollback-constraints-the-health-gate) |
| Adapter creds file | `ENV_FILE` | `~/.archon/.env` (sourced by cutover; never committed) |

See [06-workflow.md](06-workflow.md#configuration-env-vars-with-defaults) for the full table.
