# 05 — History & design rationale

This doc captures the origin of the workflow and the reasoning behind its design, so the
"why" isn't lost.

## How this repo came to be

We were improving and augmenting Archon **remotely, using Archon itself** — driving a chat
session with the bot to work on its own codebase. Concretely, we were developing our **Zulip
adapter through our already-working Zulip adapter**: editing the code of the very communication
link we were talking over. That makes shipping a change unusually risky — if a new build breaks
the adapter, you lose the channel you'd use to notice and recover.

So we wanted an easy, safe way to test and ship changes straight from the chat: one flow that
builds the new version in isolation, swaps the live server onto it, and **automatically rolls
back to the known-good build if anything regresses** — so the link is never lost. That is this
workflow.

It is deliberately generalized beyond that origin: it names no chat platform, treats "don't
regress any active integration" as the default safety rule (platform parity), and lets
operators add their own rollback constraints.

## What was built

A hot self-upgrade pipeline (`00-preflight` → `05-cutover`) that moves a live server onto a
newer target ref from a fork without a maintenance window and without dropping its active
communication link. See [01-overview](01-overview.md), [02-architecture](02-architecture.md),
and [06-workflow](06-workflow.md).

## Design decisions and the reasoning behind them

- **Build in a separate worktree; never modify the live one.** Makes rollback a clean restart
  from a known-good tree rather than an un-revert. The single most important safety property.
- **Prerequisites are the `upstream` + `myfork` remotes; deploy a `TARGET_REF` on the fork.**
  `mylive` (the currently-serving branch) is ephemeral and discovered at snapshot; `mylocal`
  feature branches are out of scope. Optional `CARRY_LIVE_COMMITS` replays `mylive`'s unmerged
  commits (patch-id aware) for the niche case that needs it.
- **The cutover must be detached (`setsid`).** The agent running the upgrade is inside the live
  server's process group; a foreground cutover would kill its own parent. A `CUTOVER_SETTLE`
  delay lets the triggering reply flush before the kill.
- **Health gate = "don't regress," not "protect a messenger."** Default success = startup +
  **platform parity** (every integration active on the old server returns), because a broken
  adapter drops out of the health endpoint's `activePlatforms`. Operators add their own rollback
  constraints (`REQUIRE_LOG`/`FORBID_LOG`, `HEALTH_CMD`/`HEALTH_HOOK`, human `CONFIRM_CMD` with a
  timeout). No platform is hardcoded or special.
- **Self-healing cutover with explicit exit codes** (`0` success / `2` rolled back / `3` manual).
  An observer (or `NOTIFY_CMD`) can act on the outcome without reading logs.
- **Isolated smoke boot under a scrubbed `ARCHON_HOME`** (a credential-blanked copy of the env
  file; no platform named). The server force-reloads its env file with `override:true`, so
  stripping the process env — or even writing a repo-scope `.env` — can't isolate it; only
  pointing `ARCHON_HOME` at a cred-blanked env keeps every adapter's presence-gate false. No
  messenger queue theft, no forge polling.
- **Scrub `CLAUDE_*` on every child server** so it doesn't mistake itself for a nested agent.

## Open items

- No top-level driver script — phases are run individually (intentional: keeps a human in the
  loop between the non-destructive phases and the destructive cutover).
- The workflow (`archon-self-upgrade.yaml`) is the canonical artifact; `scripts/` is the
  standalone equivalent of the same phases for running by hand. See
  [07-publishing](07-publishing.md) for marketplace publishing.
