# plane-roadmap-sync

Keep a project plan in one `ROADMAP.md` and mirror it **one way** to a [Plane](https://plane.so) project. The file is the truth; Plane is the board. One Dart file, no dependencies, no server: it runs on your machine, by hand or from a git hook.

- One top-level checkbox line = one work item, linked by an invisible key.
- Tick the box, commit, and the item turns Done.
- The tool writes to the one configured project and deletes nothing, ever.

## Set up in a project

You need the [Dart SDK](https://dart.dev/get-dart) 3.0 or later and a Plane project with Cycles and Modules turned on.

1. Copy `tool/plane_sync.dart` and `tool/git-hooks/post-commit` into the same paths in your repo. Keep the hook executable: `git update-index --chmod=+x tool/git-hooks/post-commit` on Windows.
2. Copy `example/plane-sync.json` to the repo root as `plane-sync.json` and fill it in (below). It holds no secret; commit it.
3. Add `secrets/` to `.gitignore`. The tool refuses to run until you have.
4. Create a personal API token in Plane (settings -> profile -> API tokens) and write `PLANE_API_KEY=<token>` into `secrets/plane.env`.
5. Write your `ROADMAP.md` in the shape below, or turn the existing one into it.
6. Push the default branch to `origin`: every `apply` compares HEAD with it, and a repo with no such ref is refused.
7. Run these in order:

```bash
dart run tool/plane_sync.dart setup    # creates the cycles, modules and labels
dart run tool/plane_sync.dart check    # lists every line as pending; read the titles
dart run tool/plane_sync.dart apply    # on the default branch: creates the items, writes the keys
git commit -m "Key the roadmap to Plane" -- ROADMAP.md
git config core.hooksPath tool/git-hooks
```

`setup` must run before the first `apply`: Plane refuses an item into a cycle whose end date has passed, so give the cycles their real, long dates.

## plane-sync.json

| Key | Meaning |
|---|---|
| `planeUrl` | Your instance, e.g. `https://plane.example.com` (`https://api.plane.so` on Plane Cloud) |
| `workspace` | The workspace slug from the URL |
| `projectId`, `identifier` | The project's id and identifier. The guard refuses any other project |
| `repoUrl` | The repo's web URL; descriptions link to the line at the commit |
| `defaultBranch` | The only branch a creating `apply` runs on, and the one every `apply` compares HEAD with on `origin`; `main` when left out |
| `cycles` | One per phase, named `Phase 0`, `Phase 1` ...: `name`, `start`, `end`, `description` |
| `modules` | The module names `setup` creates |
| `labels` | Name to colour; must hold `gate` |
| `phaseModules` | Phase to module, for every line of the phase |
| `boxModules` | Box id to module; wins over `phaseModules` |

An unknown key is refused, so a typo cannot quietly mean a default. A phase with no `phaseModules` row needs a `boxModules` row per box, or its items are born with no module (`check` prints `-`).

## The ROADMAP shape

`example/ROADMAP.md` is a complete sample, and the tests run on it.

```markdown
## Phase 1 - First playable

- [ ] **P1-01 LOGIN** - the sign-in form and the session (3-4 days)
  - **Goal:** a nested bullet; the box's own checklist, never an item.
- [x] **P1-02 SEARCH** (3 days) <!-- DEMO-14 -->
- [ ] **Gate G1** - the first read
```

**An item** is a top-level `- [ ]` / `- [x]` line under a `## Phase N` heading. Nested lines, headings and every other section (conventions, appendices) are never items, so rituals can live there.

**The key** is the trailing `<!-- DEMO-14 -->`, written by the tool at creation: Plane's sequence id under the project's identifier. Do not type or copy one.

**Ids:** `**P1-01 NAME**` (phase, then anything in capitals and digits) gives the box id the module table uses. `**Gate G1**` is a gate and gets the `gate` label. A line with neither still syncs; it follows its phase.

**The title** is `P1-01 NAME - gloss`: the first clause after the name, without a leading or trailing parenthetical, so `(3 days)` and `(session: ...)` stay out of Plane. A line with no bold name is cut at 120 characters.

To convert a plan written as headings: one top-level line per work item, the old bullets nested beneath it, a `## Phase N` heading per phase. Keep the items coarse: a box is a piece of work, its checklist stays in the file.

## What the tool owns

| Field | When | Rule |
|---|---|---|
| State | every run | Ticked = Done; `SKIPPED`, `withdrawn` or `superseded` on the line = Cancelled; else Todo |
| Cycle | every run | The phase's cycle; an open item of a closed phase rolls into the current cycle; a closed one stays out and carries `cyc:<phase>` |
| Description | when the line changed | The plain line and a permalink to it at HEAD |
| Title | creation only | As above |
| Module | creation only | `boxModules`, then `phaseModules` |
| Labels | creation only | `gate`, `cyc:<phase>` |

**Do not edit state, cycle or description in Plane:** the next run overwrites them. A hand edit of title, module or labels survives. There is no In Progress: the board shows what is finished.

## Daily use

```bash
dart run tool/plane_sync.dart check              # exit 0 in sync, 1 out of sync, 2 on a failure
dart run tool/plane_sync.dart apply              # up-to-date default branch: writes, and mints items for new lines
dart run tool/plane_sync.dart apply --no-create  # where HEAD holds the remote default branch: keyed lines only
dart run tool/plane_sync.dart setup              # creates what is missing; changes nothing that exists
```

The hook runs `apply --no-create` after a commit that touched `ROADMAP.md`; output goes to `secrets/plane-sync.log`, and it never blocks a commit. A new line becomes an item only through a deliberate `apply`, followed by a commit of its key.

- `check` and `setup` run from any checkout. Every `apply` refuses a HEAD that does not hold all of `origin/<defaultBranch>`, the main clone's too: it would write older states back. A creating `apply` also refuses any branch but the default one: a branch must not mint keys. `apply --no-create` runs in any other checkout, a detached worktree too.
- Calls are paced at 1.1 s (Plane allows 60 a minute), with a 30 s timeout, so a run starts with about 12 s of reads and the first `apply` takes a few minutes.
- The hook mirrors **the committing checkout's** `ROADMAP.md` and HEAD, a worktree's too. A worktree has no `secrets/`: the token, cache and log are read in place in the main clone, through the common git dir, and never copied.
- A tick from a worktree reaches Plane by itself: `git fetch origin`, `git checkout --detach origin/<defaultBranch>`, tick, commit, push.
- A checkout behind the remote default branch, the main clone included, is refused, in the log and never in the commit. Fetch and start from it, or pull on the main clone. The hook does not fetch, so it judges by the last fetch, which all worktrees share.
- The mirror runs at the commit, before the push. If the push is rejected, Plane is ahead of the branch until the next run.
- A branch cut from the current default branch passes too: a `ROADMAP.md` edit there reaches Plane's description before the merge, with a permalink to the branch's commit. Tick a box only after its merge and states stay right.
- With an absolute `core.hooksPath` the hook that runs is the file it names, so a new hook goes live when that checkout has it; with the relative path above each checkout runs its own.
- By hand, use an SDK at least as new as your project's: with a `.dart_tool/` in the checkout, an older `dart` refuses the package's language version. The hook does not care: it runs the tool on an empty package config.

## Rotating the token

1. Create a new token in Plane and write it into `secrets/plane.env`.
2. Run `check`: `0 change(s), 0 failure(s)` is good.
3. Delete the old token.

## Recovery

| Symptom | Meaning | Do |
|---|---|---|
| `carries DEMO-n but Plane has no such item` | The item was deleted in Plane | Remove the key from the line, commit, `apply` |
| `carries DEMO-n, as another line does` | A key was copied with a line | Remove it from the wrong line, commit; `apply` creates that line's item |
| A failure after `created DEMO-n` | The item exists and is keyed; its module or cycle post failed | Commit the key. The cycle heals on the next run; set a missed module in Plane by hand |
| A failure on a create (`! L<n>:`), with no `created` line | The item may exist all the same, if the answer was lost | Look in Plane before the next `apply`, or it mints a twin. If it exists, key the line by hand |
| `the line changed during the run: add DEMO-n by hand` | The line was edited while `apply` ran | Append `<!-- DEMO-n -->` to the line, commit |
| A live box shows Cancelled | A cancel word is on the line, in a note about part of it too | Reword the note, or nest it under the line |
| `Plane items with no keyed line` | Items the ROADMAP does not name | Left alone. Key the line by hand, or delete the item in Plane |
| `refusing: this checkout ... does not hold all of origin/...` | The commit was made behind the remote default branch, or the ref is missing | Nothing reached Plane. Fetch, redo the tick on it |
| `missing in Plane: ...; run setup first` | A cycle, module, label or state is gone | `setup`, then again |
| `refusing: the project is not ...` | `plane-sync.json` and Plane disagree | Fix the config; never remove the guard |
| `401` | The token is wrong or revoked | Rotate it |
| `404` with no detail | The workspace slug or project id is wrong | Check `plane-sync.json` |
| Every description patched at once | The cache is gone | Harmless: one run rebuilds it |

## Tests

```bash
dart pub get
dart test
```

The tests are offline: Plane is a fake in memory, the HTTP client talks to a loopback server.

## Licence

MIT. See `LICENSE`.
