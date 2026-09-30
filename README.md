# defold-git

Git collaboration panel for the [Defold](https://defold.com) editor — a
**non-modal Git window** with commit, push, pull, branches, history and
per-file diff / blame / discard, by
[WavestormSoftware](https://github.com/WavestormSoftware).

Defold's built-in *Changed Files* pane only shows local status, diff and
revert. This extension adds the missing half: committing and pushing changes,
syncing with remotes, switching branches and browsing history — all from one
panel that stays open while you edit.

## Install (60 seconds)

Requires the `git` command-line client on your `PATH` (2.19+).

**Option A — library dependency (recommended):**

1. Open your game's `game.project` → **Dependencies** → **Add**:
   `https://github.com/WavestormSoftware/defold-git/archive/main.zip`
   (pin a release instead: `https://github.com/WavestormSoftware/defold-git/archive/refs/tags/v2.0.0.zip`)
2. **Project → Fetch Libraries**
3. **Project → Git Panel** — that's the whole panel.
4. First time? **Project → Git: Setup / Doctor...** verifies git, repo state,
   remotes and identity, and can `git init` for you.

**Option B — copy the folder:**

Copy `wavestorm_git/` into your project root, then
**Project → Reload Editor Scripts**.

No native code, no extra build step, no bundled binaries — it shells out to
your system `git`.

## The Git panel

Open with **Project → Git Panel**. It is non-modal: keep editing while it
stays open (on Defold versions older than 1.13 it opens modal instead — the
layout is identical). Every action re-queries git and refreshes in place.

- **Status** — Staged and Changes lists; per file: Open, Diff, Stage/Unstage,
  Discard (with confirmation). Commit message field; Amend (auto-fills the
  previous message); Commit staged, Commit & Push, Stage all & Commit;
  Push-after-commit checkbox. Merge conflicts are listed and block commits
  until resolved (resolve in Defold's *Changed Files* pane / external client).
- **Sync** — Push / Pull / Fetch with remote and branch pickers and an
  ff-only option. The first push sets upstream automatically.
- **Branches** — switch, create & switch, delete (merged-check; force via
  checkbox), detached-HEAD and empty-repo hints.
- **History** — last N commits, each with a diff viewer.

## Also in the menus

**Project:** Git Panel · Quick Commit (stage all + message) · History ·
Setup / Doctor.

**File context (Assets / Code / Outline):** Git: Diff File · Stage File ·
Unstage File · Discard File Changes... · History for File · Blame File
(Lua files).

## Preferences

| Key | Default | Meaning |
|---|---|---|
| `wavestorm_git.default_remote` | `origin` | Preselected remote |
| `wavestorm_git.auto_save` | `true` | `editor.save()` before mutating ops |
| `wavestorm_git.push_after_commit` | `false` | Pre-tick "Push after commit" |
| `wavestorm_git.pull_ff_only` | `false` | Pre-tick "ff-only pull" |
| `wavestorm_git.confirm_discard` | `true` | Confirm before discarding |
| `wavestorm_git.history_count` | `25` | Commits listed in History |

## Notes

- Push/Pull errors mention the console; git's detailed stderr is always
  printed to the editor console.
- Empty repos, detached HEAD, missing remotes/identity and network failures
  are detected and explained instead of dumping raw output.
- Keep large binaries (PSD, WAV, …) in Git LFS or outside the repo.
- Works alongside Defold's native *Changed Files* pane; it doesn't replace it.

## Developing

```sh
lua wavestorm_git/tests/test_git.lua     # also runs on lua5.1 and luajit
```

Layout: `wavestorm_git/git.editor_script` (entry: commands + prefs),
`wavestorm_git/lib/git.lua` (exec backend + porcelain v2 parsers + ops),
`wavestorm_git/lib/panel.lua` (the panel), `wavestorm_git/lib/dialogs.lua`
(modal helpers), `wavestorm_git/tests/` (95 checks: fixtures from real git
output + live temp-repo tests).

After editing editor scripts run **Project → Reload Editor Scripts**.

## License

MIT — see [LICENSE.md](LICENSE.md).
