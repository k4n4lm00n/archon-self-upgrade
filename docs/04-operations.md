# 04 — Operations runbook

This runbook is for the standalone `scripts/` toolkit (the by-hand equivalent of the
workflow). Run the phases from a checkout of your target repo; they write `state.json`,
`logs/`, and `cutover-status.json` under `ARCHON_UPGRADE_DIR` (default
`~/.archon/.local/upgrade/`, override with the env var).

```bash
export ARCHON_UPGRADE_DIR="$HOME/.archon/.local/upgrade"   # or any scratch dir
cd /path/to/your/archon/checkout
```

## Full upgrade (happy path)

Run phases 00–04 in the foreground; they are non-destructive.

```bash
bash 00-preflight.sh    # ensure upstream + myfork remotes (fork if missing)
bash 01-snapshot.sh     # capture live identity  -> state.json
bash 02-stage.sh        # build staging worktree at TARGET_REF
bash 03-validate.sh     # install / type-check / build / (optional) tests
bash 04-smoke.sh        # isolated boot on :3091 (adapters disabled), then killed
```

Only proceed to cutover if all pass. **Launch the cutover detached** — it kills
the process group your shell is in:

```bash
setsid bash 05-cutover.sh </dev/null >logs/cutover.log 2>&1 &
```

Then stop typing in that shell and watch from outside (see below). If you are driving
this from inside a chat with the bot, send the launch command and expect the bot to go
briefly silent while it restarts.

## Watching a cutover

```bash
# machine-readable status (updated at each transition)
cat cutover-status.json

# live log
tail -f logs/cutover.log

# is the live port back up?
ss -ltn | grep 3090
```

Terminal states in `cutover-status.json`:

| `phase` | Meaning | Exit |
|---------|---------|------|
| `success` | new build serving on :3090 | 0 |
| `rolled_back` | new build was unhealthy; old build restored, link back | 2 |
| `FAILED` | rollback also failed — **manual intervention** | 3 |

## If it rolled back (`rolled_back`)

Service is intact on the old build. Investigate `logs/server-new.log` for why the new
build failed the health gate (see the `[gate]` lines in `cutover.log`), fix in staging,
re-run from `02-stage.sh`.

## If it FAILED (`FAILED`)

The link is down. Manually restart the known-good old worktree (from `state.json`):

```bash
OLD=$(grep -oE '"live_worktree"[^,]*' state.json | cut -d'"' -f4)
cd "$OLD"
setsid env PATH="$HOME/.bun/bin:$PATH" PORT=3090 bun run dev \
  </dev/null >/tmp/archon-manual.log 2>&1 &
grep -q server_ready /tmp/archon-manual.log   # wait for this (and your messenger marker, if any)
```

## Cold start (after a host restart)

The phases above assume a **running** server to swap. After a host or container restart
there is none — and the only record of which worktree was serving is in the run artifacts.
`scripts/start-current.sh` reads them and boots that build:

```bash
scripts/start-current.sh --detect-only   # print what it would start, change nothing
scripts/start-current.sh                 # start + gate, then exit
scripts/start-current.sh --entrypoint    # start + gate, then hold the foreground and
                                         # forward SIGTERM/SIGINT to the server group
```

Detection order — first hit wins, it never guesses:

1. **a server already running** → adopt it and exit 0, so re-running is harmless
2. **`$POINTER`** (`$ARCHON_HOME/.local/current-live.json`) — rewritten on every healthy start
3. **the newest `cutover-status.json`** under `$ARCHON_UPGRADE_DIRS` — `success` and
   `rolled_back` both name the serving worktree in `detail`; any other phase falls back to
   `live_worktree` in the sibling `state.json`

If nothing resolves, or the resolved worktree is missing / not a worktree root / has no
installed dependencies, it exits 1 **without starting anything**. Exit 2 means it started
but did not pass the gate — the server is left running for inspection (there is nothing to
roll back to on a cold start; that is the cutover's job).

It reuses the toolkit's env-var names and defaults (`LIVE_PORT`, `DEV_CMD`,
`BIN_PATH_PREPEND`, `READY_MARKER`, `MESSENGER_READY_MARKER`, `HEALTH_URL`,
`REQUIRE_PLATFORMS`, `START_DEADLINE`), plus `POST_START_CMD` for a one-off command. It does
**not** source `lib.sh`, so a single copy of the file is enough:

```bash
# deploy it next to your other host scripts — no privileged path, no root
install -m 0755 scripts/start-current.sh "${ARCHON_HOME:-$HOME/.archon}/scripts/start-current-archon.sh"
```

A user-owned path is enough for a service unit or a container `--entrypoint`, and it keeps
the deployed copy on the same persistent volume as the run artifacts it reads. Re-run the
`install` after changing the script — the deployed copy is a copy, not a link.

Where the toolkit writes run artifacts to a scratch directory (`ARCHON_UPGRADE_DIR=/tmp/...`),
put them somewhere that survives a restart — otherwise the cold start has nothing to read.

### Boot hooks — what else comes back up

A server restart also takes down everything *around* it: pollers, sync daemons, tunnels,
watchdogs. Those are not the server's to restart, and a server generally has no way to be
told about them. So once the health gate passes, `start-current.sh` runs every executable in
`$BOOT_HOOKS_DIR` (default `$ARCHON_HOME/.local/boot.d`) in lexical order:

```bash
install -m 0755 boot.d/10-my-daemon.sh "${ARCHON_HOME:-$HOME/.archon}/.local/boot.d/"
```

A project registers itself by shipping one hook file and installing it — the set of things
that must come back lives with the projects that own them, not in one host script that
drifts. Contract:

- **Idempotent.** Hooks also run when the script adopts an already-running server, so a bare
  re-run doubles as a repair pass. Delegate to a launcher that checks a pidfile and exits 0
  if the process is already up.
- **Non-fatal.** A hook's failure is logged and the boot continues — the server is up, and
  one broken side process must not turn a good boot into a bad one.
- **Bounded.** Each hook is capped at `BOOT_HOOK_TIMEOUT_S` (default 60s, `0` disables), so a
  hook that hangs cannot hang the boot.
- **Env provided:** `SERVER_URL`, `LIVE_PORT`, `LIVE_WT`, `SERVER_PGID`, `ACTIVE_PLATFORMS`,
  `SERVER_LOG`.

`--no-hooks` starts the server alone.

## Common issues

- **`no live '<comm>' process matching '<pattern>'`** — the server isn't up, or runs under
  a different command. `01-snapshot` and cutover re-detection need both a
  `LIVE_PROC_PATTERN` match and `/proc/<pid>/comm` = `LIVE_PROC_COMM` (`lib.sh:live_pid`).
  If your server runs under a different binary (a compiled build, a wrapper), set
  `LIVE_PROC_COMM` to match.
- **`CONFLICT carrying <sha>`** (02-stage, only with `CARRY_LIVE_COMMITS=1`) — a carried
  local commit conflicts with the target. Staging is left clean; resolve the conflict (or
  set `CARRY_LIVE_COMMITS=0` to deploy the target as-is) and re-run.
- **`migration set differs`** (03-validate) — schema drift between live and staging;
  confirm migrations apply at startup before cutover.
- **Port still busy after stop** — the old group didn't die; check for stray `bun`
  processes before starting the new build.
