# archon-self-upgrade

A **hot self-upgrade toolkit** for a live Archon server: swap the running server to
newer code from your fork **without dropping its active messenger link** (whatever comm
channel it keeps open) — with staged builds, an isolated smoke boot, and automatic
rollback on failure.

The tricky part: the Archon server holds an open messenger link, and the agent that
runs the upgrade lives **inside that server's process group**. So the cutover has to kill
and replace the very process tree it is running in, and still guarantee the link
comes back — or roll itself back if it doesn't.

## Scope

Part of our work **extending Archon to our own needs** (adapters, plugins, workflows,
providers) and **fixing core limitations that block that work** — here, upgrading our own
running server safely. We keep our fork compatible with upstream `dev` so maintainers can
merge effortlessly; **upstream CI / infrastructure health is the maintainers' concern, not
ours** — we don't chase green pipelines on infra we don't own.

> This README is the global index. Details live in [`docs/`](docs/).
>
> **One source of truth, two front doors.** [`scripts/`](scripts/) (`lib.sh` + `00`–`05`) is
> the **canonical implementation** — all logic (target resolution, isolation, the health gate,
> rollback, known-good promotion) lives there and nowhere else. Run it by hand, or drive it
> through [`archon-self-upgrade.yaml`](archon-self-upgrade.yaml), which is now a **thin Archon
> workflow**: each node just `exec`s the matching phase script, adding the workflow surface
> (chat trigger, per-step status, artifacts, resumability). No logic is duplicated between the
> two. See [docs/06-workflow.md](docs/06-workflow.md) and [docs/07-publishing.md](docs/07-publishing.md).

---

## How to run

Trigger it from an Archon topic scoped to your Archon checkout (or
`/invoke-workflow archon-self-upgrade --project <name> --prompt "<prompt>"`). Just type what
you want after **`to`** — the workflow figures out where the ref lives:

| You want to upgrade to… | Prompt exactly |
|-------------------------|----------------|
| your fork's **current dev** | `self upgrade to dev` |
| the **latest stable release** | `self upgrade to the latest stable release` |
| a **specific / previous release** (down- or up-grade) | `self upgrade to v0.5.0` |
| **`upstream`'s** current dev/main | `self upgrade to upstream/dev` |
| a **specific branch on your fork** | `self upgrade to myfork/feat/my-change` |
| a **branch on someone else's fork** (e.g. review a PR) | `self upgrade to alice/Archon@feat/her-change` |
| a **specific commit** | `self upgrade to 1a2b3c4` |
| your fork's default branch (no target) | `self upgrade` |

**Carrying your local commits (off by default).** Most deployments track a fork/upstream ref with
no unmerged local work, so by default the run deploys the **bare target**. If you *do* run local
commits on top of the target, turn carry on **persistently** — a per-host preference, set once:

```bash
/self-upgrade set carry-live-commits yes     # or: scripts/self-upgrade-config.sh set carry-live-commits yes
```

With carry on, every run **re-applies your unmerged commits on top of the target** (patch-id aware —
anything already merged upstream is dropped, nothing double-applies), seeded from the blessed
known-good manifest when present, else from the live branch. For a single run you can instead pass
`CARRY_LIVE_COMMITS=1` as an env var (it overrides the saved preference); `CARRY_LIVE_COMMITS=0`
forces the bare target for one run. On a carry conflict the run stops with the staging worktree
left clean (resolve by hand or turn carry off). The preference lives in a host-local config file
(`config.env`), never in the committed workflow YAML, so it survives redeploys.

Notes:
- A bare branch name (`self upgrade to feat/x`) is looked up on **your fork first, then
  `upstream`**. Use `upstream/…` or `alice/Archon@…` to be explicit.
- Third-party specs are `<owner>/<repo>@<branch>` (assumes GitHub) or `<git-url>@<branch>`.
- If the target you name can't be found, the run **stops with an error** — it never silently
  deploys something else. (No `to …` at all = your fork's default branch.)
- Equivalent env vars (they override the prompt and any saved preference): `TARGET_REF=<any git ref>`
  and `CARRY_LIVE_COMMITS=1` (carry is off by default). See [docs/06-workflow.md](docs/06-workflow.md) for the full config
  and rollback constraints.

---

## The pipeline

```
00-preflight ─▶ 01-snapshot ─▶ 02-stage ──▶ 03-validate ─▶ 04-smoke ──▶ 05-cutover
  ensure          capture        build @       install/       boot on       stop old · start new
  upstream +      live identity  TARGET_REF    typecheck/     :3091 with    on :3090 · wait for
  myfork (fork    as rollback    (isolated     build/test     no adapters   READY_MARKER +
  if missing)     anchor         worktree)     (non-destr.)   (isolated)    HEALTH GATE
                                                                            └─ fails? ROLL BACK
                                                                               to old worktree
```

Phases 00–04 are **non-destructive** — they never touch the live server. Only
`05-cutover` is destructive, and it is self-healing: if the new build fails the **health gate**
within the deadline, it restarts the **old worktree** (never modified) and confirms it is back.

## Cold start (the other half)

The pipeline **swaps** a running server. After a host or container restart there is nothing
to swap: the process group is gone, and only the run artifacts remember which worktree was
serving. [`scripts/start-current.sh`](scripts/start-current.sh) closes that gap — it reads
those artifacts, boots the build that was live, and applies the same startup gate.

```bash
scripts/start-current.sh --detect-only   # print what it would start, change nothing
scripts/start-current.sh                 # start it, gate it, run boot hooks, then exit
scripts/start-current.sh --entrypoint    # ... and stay in the foreground (service/container PID 1)
```

Once the server is healthy it runs every executable in `$BOOT_HOOKS_DIR`
(default `$ARCHON_HOME/.local/boot.d`) — the side processes a server does not own: pollers,
sync daemons, tunnels. Each project installs one hook there, so what comes back after a
restart is owned by the projects rather than by one host script. Hooks must be idempotent;
they run on the adopt path too, which makes a bare re-run a repair pass.

It is self-contained by design (no `lib.sh`), so it can be copied to a fixed path and used
as an entrypoint on a host that has no toolkit checkout. See
[docs/04-operations.md](docs/04-operations.md#cold-start-after-a-host-restart).

## Key design decisions

| Decision | Why |
|----------|-----|
| Prerequisites are the `upstream` + `myfork` remotes; deploy a **`TARGET_REF`** on the fork (optional patch-id **carry** of `mylive`'s unmerged commits) | Ensures a durable fork to deploy from (created if missing); lets you point the upgrade at any pushed ref while optionally preserving local, not-yet-merged work. |
| **Old worktree is never modified** | Rollback is always a clean restart from a known-good tree — no un-reverting, no half-states. |
| Cutover runs **fully detached** (`setsid … </dev/null &`) | The launching agent lives in the live server's process group; a foreground cutover would kill its own parent. |
| Health gate defaults to **platform parity** — every integration active on the old server must return — plus pluggable operator constraints (`REQUIRE_LOG`/`FORBID_LOG`, `HEALTH_CMD`/`HEALTH_HOOK`, human `CONFIRM_CMD` w/ timeout) | "Don't regress" is the real goal, not "protect one messenger." No platform is special; rollback fires if *anything* that worked stops working, or any operator check fails. |
| `CUTOVER_SETTLE` delay before the kill | Lets the launching agent's chat reply flush before its own server dies. |
| Scrub `CLAUDE_*` env on the child server | Prevents the new server from thinking it is a nested Claude agent. |
| Smoke boot runs under a scrubbed `ARCHON_HOME` (credential-blanked copy of the env file) | The server self-loads its env, so the boot must load a cred-blanked copy instead — every adapter's presence-gate is false, so it connects to nothing (no messenger queue theft, no forge polling) while DB/other config still load. |

## Status

- One implementation (`scripts/`), two front doors: run the phase scripts by hand, or drive
  them through the thin `archon-self-upgrade.yaml` workflow (each node `exec`s a script). See
  [`docs/04-operations.md`](docs/04-operations.md). The workflow finds the scripts at
  `SELFUPGRADE_SCRIPTS` (default `$HOME/.archon/.local/upgrade`), and its `preflight` node
  **self-bootstraps** them from the published repo on first run if they aren't installed yet —
  so the single YAML works straight from the marketplace.
- No top-level driver script — phases are run individually, keeping a human in the loop
  between the non-destructive phases and the destructive cutover.

## Documentation map

| Doc | Contents |
|-----|----------|
| [01-overview.md](docs/01-overview.md) | The problem, the constraint, what "success" means |
| [02-architecture.md](docs/02-architecture.md) | Pipeline, state machine, rollback guarantee, host assumptions |
| [03-phases.md](docs/03-phases.md) | Per-script reference (`lib.sh` + `01`–`05`) |
| [04-operations.md](docs/04-operations.md) | Runbook: run it, detached cutover, check status, roll back |
| [05-history.md](docs/05-history.md) | How this repo came to be; conversation summary & decisions |
| [06-workflow.md](docs/06-workflow.md) | The `archon-self-upgrade.yaml` workflow: prereqs, DAG, config env vars |
| [07-publishing.md](docs/07-publishing.md) | Publishing to the Archon marketplace (paste-ready entry) |

## Layout

```
scripts/                     the canonical implementation — single source of truth (lib.sh, 00…05)
scripts/self-upgrade-config.sh  manage persistent per-host preferences (set/get/unset)
archon-self-upgrade.yaml     thin Archon workflow: each node exec's the matching phase script
commands/self-upgrade.md     /self-upgrade command: run an upgrade, or set/get/unset a preference
scripts/start-current.sh     cold start: detect the last live build and boot it (entrypoint-ready)
reference/                   sanitized example state files (runtime state.json is gitignored)
docs/                        this documentation
LICENSE                      MIT
```

## Publishing checklist (marketplace)

- [x] `LICENSE` (MIT).
- [x] Canonical workflow parameterized (env vars, no hardcoded host paths); validates against
      Archon's `parseWorkflow` (schema + DAG).
- [x] No secrets in the tree (adapter creds sourced from `ENV_FILE` at run time).
- [x] `logs/`, `state.json`, `.env` gitignored.
- [ ] Push to `github.com/k4n4lm00n/archon-self-upgrade`, pin SHA, open marketplace PR —
      see [docs/07-publishing.md](docs/07-publishing.md).
