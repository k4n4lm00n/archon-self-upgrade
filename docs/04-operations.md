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

## Common issues

- **`could not find a running 'bun --watch src/index.ts'`** — the server isn't up, or
  runs under a different command. `01-snapshot` and cutover re-detection depend on that
  process name (`lib.sh:detect_live`).
- **`CONFLICT carrying <sha>`** (02-stage, only with `CARRY_LIVE_COMMITS=1`) — a carried
  local commit conflicts with the target. Staging is left clean; resolve the conflict (or
  set `CARRY_LIVE_COMMITS=0` to deploy the target as-is) and re-run.
- **`migration set differs`** (03-validate) — schema drift between live and staging;
  confirm migrations apply at startup before cutover.
- **Port still busy after stop** — the old group didn't die; check for stray `bun`
  processes before starting the new build.
