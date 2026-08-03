# 01 — Overview

## The problem

Archon runs as a long-lived server (`bun run dev` on `:3090`) that also holds an open
**messenger link** (whatever communication channel it serves — a chat bot, a webhook
listener, etc.). Development happens on a fork; the fork tip moves ahead of whatever the
live server is running. We want to move the live server onto newer code **without a
maintenance window and without dropping that link** — ideally driven from *inside* the
very channel the bot serves.

That last part is the hard constraint: the agent that performs the upgrade is a child
of the live server's process group. When the cutover kills the server, it kills the
agent's own parent. So the destructive step cannot be run in the foreground of the
agent's shell — it must be detached and self-supervising.

## What "success" means

A cutover is only successful when the new build reaches **both**:

1. `READY_MARKER` (e.g. `server_ready`) — startup finished, HTTP server is up, and
2. **platform parity** — the health endpoint reports the *same set of active platforms* the old
   server had (an adapter only counts once its `start()` succeeds), plus any operator-defined
   rollback constraints (see [06-workflow](06-workflow.md#rollback-constraints-the-health-gate)).

An HTTP-200 alone is *not* success: the point is that the new version is at least as healthy as
the old one — no integration silently dropped.

## Non-negotiables

- **The live server is never modified in place.** New code is built in a separate
  git worktree. The old worktree is left byte-for-byte untouched so rollback is a
  clean restart from a known-good tree.
- **Phases 00–04 have zero effect on production.** Only `05-cutover` touches the live
  process, and it guarantees rollback if the new build is unhealthy.
- **The smoke boot connects to nothing.** It runs under a scrubbed `ARCHON_HOME` (a
  credential-blanked copy of the env file), so every adapter's presence-gate is false and the
  staged build cannot steal the messenger event queue or poll forges while it is tested.

## Runtime locations (defaults)

| Thing | Default (env override) |
|-------|------------------------|
| Runtime state / logs | `~/.archon/.local/upgrade/` (`ARCHON_UPGRADE_DIR`) |
| Live worktree | discovered at snapshot, recorded in `state.json` |
| Staging worktree | `~/worktrees/archon-upgrade-next` (`STAGE_WT`) |
| Adapter creds | `~/.archon/.env` (`ENV_FILE`; sourced at runtime, never committed) |

See [02-architecture.md](02-architecture.md) for how the phases fit together and
[04-operations.md](04-operations.md) for how to run it.
