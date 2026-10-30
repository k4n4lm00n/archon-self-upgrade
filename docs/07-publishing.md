# 07 — Publishing to the Archon marketplace

The Archon marketplace is a curated list in **`coleam00/Archon`** at
`packages/docs-web/src/data/marketplace.ts`. Third-party workflows live in the author's own
GitHub repo; the marketplace entry points at a **SHA-pinned** GitHub URL. Publishing is a PR
that adds one `MarketplaceEntry`.

## Steps

1. **Push this repo to GitHub** (public), under the authenticated account `k4n4lm00n`:
   ```bash
   gh repo create k4n4lm00n/archon-self-upgrade --public --source=. --push
   ```
2. **Get the commit SHA** to pin (the marketplace requires a full SHA, not a branch):
   ```bash
   git rev-parse HEAD
   ```
3. **Validate locally** (optional but recommended) — run it through Archon's loader; a clean
   parse means no schema/DAG errors. (In an isolated checkout you may see a benign
   `Unknown provider 'claude'` — that's the provider registry not being booted, not a defect;
   the shipped default workflows report the same in that context.)
4. **Fork `coleam00/Archon`, add the entry** below to `packages/docs-web/src/data/marketplace.ts`,
   filling in the SHA from step 2, then run the marketplace lint:
   ```bash
   bun packages/docs-web/scripts/lint-marketplace.ts
   ```
5. **Open the PR.** CI runs `Marketplace Lint` + `marketplace-auto-review`.

## Paste-ready entry

```ts
{
  slug: 'archon-self-upgrade',
  name: 'Archon Self-Upgrade',
  author: 'k4n4lm00n',
  description:
    'Hot-upgrade a live, long-running server (e.g. an Archon messenger-integrated bot) to newer ' +
    'code from your fork WITHOUT dropping its active communication link. Ensures the `upstream` ' +
    'and `myfork` remotes (forks `upstream` to create `myfork` if missing), snapshots the live ' +
    'instance as a rollback anchor, stages the target ref in an isolated worktree, ' +
    'installs/type-checks/builds/tests, smoke-boots in isolation (no adapter connects), then ' +
    'performs a detached, self-healing cutover that keeps every active integration or rolls back.',
  sourceUrl: 'https://github.com/k4n4lm00n/archon-self-upgrade/blob/<COMMIT_SHA>/archon-self-upgrade.yaml',
  sha: '<COMMIT_SHA>',
  tags: ['automation', 'development'],
  archonVersionCompat: '>=0.3.0',
},
```

Notes:
- **Single-file blob is still valid** even though the logic now lives in `scripts/` (the single
  source of truth). The `preflight` node is **self-bootstrapping**: if the toolkit isn't already
  installed at `SELFUPGRADE_SCRIPTS` (default `$HOME/.archon/.local/upgrade`), it clones the
  published repo (`SELFUPGRADE_REPO`, default `github.com/k4n4lm00n/archon-self-upgrade`;
  `SELFUPGRADE_REF`, default `main`) and installs `scripts/*.sh` there on first run. So a marketplace
  user who fetches only `archon-self-upgrade.yaml` gets a working workflow with no separate install
  step. (Pin `SELFUPGRADE_REF` to a tag/SHA if you want the fetched scripts locked to a release.)
- Keep `sourceUrl`'s `<COMMIT_SHA>` and the `sha` field identical.
- `requires: [github]` in the workflow means users must have a connected GitHub identity —
  surfaced by the marketplace as a prerequisite.

## Pre-publish checklist

- [x] `LICENSE` present (MIT).
- [x] No secrets in the tree (creds are sourced from `ENV_FILE` at run time).
- [x] Workflow validates against `parseWorkflow` (schema + DAG).
- [ ] Repo pushed to `github.com/k4n4lm00n/archon-self-upgrade`.
- [ ] SHA pinned in the marketplace entry.
- [x] Platform-agnostic: no chat platform named in the workflow. Rollback defaults to
      platform parity; adopters add their own constraints (`REQUIRE_LOG`/`FORBID_LOG`,
      `HEALTH_CMD`/`HEALTH_HOOK`, human `CONFIRM_CMD`). See docs/06.
