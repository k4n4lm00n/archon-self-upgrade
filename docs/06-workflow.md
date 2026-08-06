# 06 — The `archon-self-upgrade` workflow

[`archon-self-upgrade.yaml`](../archon-self-upgrade.yaml) is the **publishable, generalized**
version of this toolkit: a self-contained Archon DAG workflow. It inlines the logic of the
`scripts/` reference implementation so it needs no external files at run time (portable across
hosts and safe to fetch from the marketplace).

> `scripts/` is the original, host-specific reference implementation (documents the `myfork`
> single-remote origin). The **YAML is canonical** for the published workflow and uses the
> corrected two-remote model below.

## Prerequisites

| Prereq | Kind | Enforcement |
|--------|------|-------------|
| GitHub identity connected | schema `requires: [github]` | Run is hard-blocked before any cost if absent. |
| `upstream` remote | git remote | `preflight` adds it from `UPSTREAM_URL` if missing. |
| `myfork` remote | git remote | `preflight` runs `gh repo fork` to create it if missing. |

Terminology (per the design discussion):
- **`upstream`** — the canonical repo you track (default `coleam00/Archon`).
- **`myfork`** — *your* fork (e.g. `k4n4lm00n/Archon`). The durable home for what you deploy.
- **`mylive`** — the branch/worktree currently serving. Ephemeral; changes every upgrade;
  discovered automatically at `snapshot`.
- **`mylocal`** — your in-flight feature branches (there can be several). **Not** the target;
  push the one you want live to `myfork` and pass it as `TARGET_REF`.

## The DAG

```
preflight ─▶ snapshot ─▶ stage ─▶ validate ─▶ smoke ─▶ cutover
 remotes +    rollback    target    install/     isolated  detached,
 config       anchor      worktree  typecheck/   boot,     self-healing
 (requires    (mylive)    @TARGET   build/test   health-   (keeps link
  github)                                        checked   or rolls back)
```

`depends_on` chains them, and a non-zero exit fails a node — so **`cutover` only runs if
`smoke` proved the build boots and serves.** No human approval gate (per design): the
automated smoke gate plus the self-healing cutover are the safety mechanism.

### How "is staging fine?" is checked automatically (no human gate)
- **`smoke`** boots the staged build on `SMOKE_PORT` under a scrubbed `ARCHON_HOME` (a
  credential-blanked copy of the env file, so no adapter starts) and waits for `READY_MARKER`
  + an HTTP response. Connects to nothing; proves the build runs.
- **`cutover`** applies the **health gate** (see [Rollback constraints](#rollback-constraints-the-health-gate)):
  by default the new build must reach `READY_MARKER` **and** its health endpoint must report the
  same set of active platforms the old server had (**platform parity**). If the gate fails within
  `CUTOVER_DEADLINE`, it **rolls back** to the untouched live worktree. The guarantee: *the new
  version is at least as healthy as the old, or the upgrade is aborted.*

### Why cutover is detached, and how you learn the outcome
The cutover replaces the very process group the workflow runs inside, so the `cutover` node
writes a self-contained runner to `$ARTIFACTS_DIR/run-cutover.sh`, launches it with `setsid`,
and returns immediately. The detached runner reports the terminal outcome three ways:
- `$ARTIFACTS_DIR/cutover-status.json` → `success` | `rolled_back` | `FAILED`
- `$ARTIFACTS_DIR/cutover.log`
- **`NOTIFY_CMD`** — if set, called as `"$NOTIFY_CMD "<message>""` on success/rollback/failure.
  Point it at the originating messenger's notifier to be told the result *through the very
  channel you're protecting*.

Exit codes of the runner: `0` success · `2` rolled back cleanly · `3` rollback also failed
(manual intervention).

## Configuration (env vars, with defaults)

All host specifics are env vars resolved in `preflight` and persisted to
`$ARTIFACTS_DIR/upgrade.env`. Override via project/workflow env.

| Var | Default | Purpose |
|-----|---------|---------|
| `UPSTREAM_REMOTE` | `upstream` | Canonical remote name. |
| `UPSTREAM_URL` | `https://github.com/coleam00/Archon` | Used to add `upstream` / fork from. |
| `FORK_REMOTE` | `myfork` | Your fork's remote name. |
| `TARGET_REF` | *(fork default branch)* | What to deploy. Precedence: env > a ref named in the trigger message > fork default branch. |
| `LIVE_PORT` / `SMOKE_PORT` | `3090` / `3091` | Live and isolated-smoke ports. |
| `STAGE_WT` / `STAGE_BRANCH` | `~/worktrees/archon-upgrade-next` / `archon-upgrade-next` | Staging worktree/branch. |
| `LIVE_PROC_PATTERN` | `bun --watch src/index.ts` | `pgrep` pattern to find the live server. |
| `LIVE_PROC_COMM` | first word of `DEV_CMD` (`bun`) | `/proc/<pid>/comm` a match must have to count as the server — keeps a command line that merely mentions the pattern from being mistaken for it. |
| `DEV_CMD` | `bun run dev` | Command to start the server. |
| `INSTALL_CMD` / `TYPECHECK_CMD` / `BUILD_CMD` | `bun install` / `bun run type-check` / `bun run build` | Validation steps (empty = skip). |
| `TEST_CMD` | *(empty)* | Optional test command, e.g. `bun test`. |
| `BIN_PATH_PREPEND` | `~/.bun/bin` | Prepended to `PATH` for server/validate. |
| `READY_MARKER` | `server_ready` | Log line meaning startup finished (HTTP server up). |
| `SCRUB_ENV_VARS` | *(empty)* | Extra env var names to blank in the smoke boot's scrubbed `ARCHON_HOME` env, on top of the automatic credential-pattern set. |
| `CUTOVER_SETTLE` | `45` | Seconds before killing old (lets the triggering reply flush). |
| `CARRY_LIVE_COMMITS` | `0` | `1` = replay `mylive`'s unmerged commits onto the target (patch-id aware). |
| `ENV_FILE` | `~/.archon/.env` | Sourced by cutover for adapter creds. |
| `NOTIFY_CMD` | *(empty)* | Optional outcome notifier (see above). |

### Health-gate / rollback-constraint knobs

| Var | Default | Purpose |
|-----|---------|---------|
| `CUTOVER_DEADLINE` | `150` | Max seconds to become healthy → **"rollback if startup takes longer than N"**. |
| `HEALTH_URL` | `http://127.0.0.1:$LIVE_PORT/api/health` | Endpoint polled for `status:ok` + `activePlatforms`. |
| `SKIP_PLATFORM_PARITY` | `0` | `1` disables the platform-parity check. |
| `REQUIRE_PLATFORMS` | *(auto)* | `;`-list overriding the auto-captured old platform set the new build must restore. |
| `REQUIRE_LOG` | *(empty)* | `;`-list of regexes that **must appear** in the new server log → rollback if absent. |
| `FORBID_LOG` | *(empty)* | `;`-list of regexes that **must not appear** → rollback if any is seen. |
| `HEALTH_CMD` | *(empty)* | Arbitrary command; must exit `0`. Env: `NEW_LOG`, `SERVER_URL`, `LIVE_PORT`. |
| `HEALTH_HOOK` | *(empty)* | Path to an executable operator hook; must exit `0` (same env as `HEALTH_CMD`). |
| `CONFIRM_CMD` | *(empty)* | Command that blocks until a human confirms; non-zero **or timeout** → rollback. |
| `CONFIRM_TIMEOUT_S` | `600` | Confirmation window (default 10 minutes). |

See the next section for what these do together and copy-paste examples.

## Rollback constraints (the health gate)

After the new build starts, the cutover runs it through the **health gate**. If **any** check
fails — or the whole thing doesn't pass within `CUTOVER_DEADLINE` — the cutover kills the new
build and restores the untouched old worktree. The gate has two layers:

**1. The default gate (always on, generic).** No configuration, no platform named:
- the new server log shows `READY_MARKER` (startup finished), and
- `HEALTH_URL` reports `status: ok` **and** every platform that was active on the *old* server
  is active again (**platform parity**). Because a platform only appears once its adapter's
  `start()` succeeds, this means: *break any integration and the upgrade rolls back.*

  This is why there's no "messenger" setting. The messenger isn't special — it's just one of
  the platforms in the parity set. **No messenger connected** (triggered from the UI/API)? The
  set is just `["Web"]`; the gate still works. **Several messengers?** All of them must come
  back; if any fails, rollback. **Editing an adapter (e.g. yours)?** If your change stops it
  from starting, it drops out of the set → rollback — automatically, with nothing hardcoded.

**2. Operator constraints (optional, add your own).** Layer any of these on top; each becomes
an extra reason to roll back. They compose — set as many as you like.

```bash
# Roll back if a specific string appears in the new server's log (a crash signature, etc.)
FORBID_LOG='FATAL;unhandledRejection;adapter .* failed'

# Roll back unless a specific string appears (belt-and-suspenders for a particular subsystem)
REQUIRE_LOG='<your-adapter>.bot_started;migrations applied'

# Roll back if the new build isn't healthy within 90s (shorter than the 150s default)
CUTOVER_DEADLINE=90

# Roll back unless an arbitrary check passes (exit 0). Env available: SERVER_URL, NEW_LOG, LIVE_PORT.
HEALTH_CMD='curl -fsS "$SERVER_URL" >/dev/null && curl -fsS localhost:$LIVE_PORT/api/health | grep -q "\"status\":\"ok\""'

# Or point at a script for anything complex (metrics, a synthetic transaction, an external probe)
HEALTH_HOOK=/etc/archon/upgrade-health.sh

# Ask a human to confirm on some channel, and roll back if they don't within 10 minutes.
# CONFIRM_CMD blocks until it exits 0 (confirmed) or the timeout fires (=> rollback).
CONFIRM_CMD='/etc/archon/ask-and-wait.sh "#ops"'   # posts a prompt, polls for a 👍 reply, exit 0 when seen
CONFIRM_TIMEOUT_S=600
```

Notes:
- Lists (`REQUIRE_LOG` / `FORBID_LOG` / `REQUIRE_PLATFORMS`) are `;`-separated; each entry in the
  log lists is an **extended regex**.
- Evaluation order: startup → platform parity → `REQUIRE_LOG` → `HEALTH_CMD` → `HEALTH_HOOK` →
  `CONFIRM_CMD`. `FORBID_LOG` is checked continuously and fails fast.
- The human `CONFIRM_CMD` runs **last**, only after the automated checks pass, so you're only
  ever asked to bless a build that already looks healthy. During the confirmation window the new
  build is already live (a canary); not answering in time is a safe rollback, because the old
  worktree was never touched.
- On rollback, the restored old build is validated with the **default gate only** (startup +
  parity) — your `CONFIRM_CMD`/`REQUIRE_LOG` etc. apply to *validating the new version*, not to
  bringing the known-good one back.

## Running it

See the README's **[How to run](../README.md#how-to-run)** section for how to trigger the
workflow and the exact prompt for each target (fork dev, latest/a specific release, an
`upstream` or fork branch, someone else's fork, a specific commit), plus the `TARGET_REF` /
`CARRY_LIVE_COMMITS` env overrides. The target named after `to` is resolved in the `preflight`
node.

See [07-publishing.md](07-publishing.md) to publish it to the marketplace.
