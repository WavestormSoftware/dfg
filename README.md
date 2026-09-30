# defold-git

Git collaboration panel for the [Defold](https://defold.com) editor — commit,
push, pull, branches, history, diff / revert / blame — without leaving the
editor. By [WavestormSoftware](https://github.com/WavestormSoftware).

Defold's built-in *Changed Files* pane only shows local status, diff and
revert. This extension adds the missing half: committing and pushing changes,
syncing with remotes, switching branches and browsing history.

## Install (60 seconds)

Requires the `git` command-line client on your `PATH`.

**Option A — as a library dependency (recommended):**

1. Open your game's `game.project` → **Dependencies** → **Add** this URL:
   `https://github.com/WavestormSoftware/defold-git/archive/main.zip`
   (to pin a release instead: `https://github.com/WavestormSoftware/defold-git/archive/refs/tags/v1.0.0.zip`)
2. **Project → Fetch Libraries**
3. **Project → Git: Setup / Doctor...** — verifies git, repo state, remotes
   and `user.name` / `user.email`
4. **Project → Git: Status / Commit & Push...** for daily work

**Option B — copy the folder:**

Copy `wavestorm_git/` into your project root, then
**Project → Reload Editor Scripts**.

No native code, no extra build step, no bundled binaries — the extension
shells out to your system `git`.

## Commands

**Project menu:**

| Command | What it does |
|---|---|
| Git: Status / Commit & Push... | Main panel: tick files, write a message, Commit or Commit & Push. Shows branch, upstream, ahead/behind and conflicts. |
| Git: Quick Commit... | Stage everything (`git add -A`) and commit with one message. |
| Git: Push... | Push the current branch to a chosen remote (sets `-u` when there is no upstream yet). |
| Git: Pull... | Pull from a chosen remote. Saves open files first. |
| Git: Fetch | `git fetch --all`, then shows the branch summary. |
| Git: History... | Last N commits (configurable, default 25). |
| Git: Branches... | Switch branch, or create and switch to a new one. |
| Git: Setup / Doctor... | Checks git version, repo state, branch, remotes, identity and `.gitignore`. Offers `git init` for non-repos. |

**File context (Assets / Code / Outline):** Git: Diff File, Git: Revert File...,
Git: History for File, Git: Blame File (code files).

## Preferences

Set automatically on first load; edit via the editor's preferences:

- `wavestorm_git.default_remote` (`"origin"`)
- `wavestorm_git.auto_save` (`true`) — save open files before commit / push / pull / switch / revert
- `wavestorm_git.push_after_commit` (`false`) — pre-tick "Push after commit"
- `wavestorm_git.history_count` (`25`)

## Notes

- Merge conflicts must be resolved in an external client; the panel lists
  conflicted files and refuses to stage them.
- Read-only operations never trigger a resource reload; mutating ones do, so
  the Assets view stays in sync.
- Keep large binaries (PSD, WAV, …) in Git LFS or outside the repo.
- Works alongside Defold's native *Changed Files* pane, it doesn't replace it.

## Developing

```sh
lua wavestorm_git/tests/test_git_core.lua
```

Layout: `wavestorm_git/git.editor_script` (command registration),
`wavestorm_git/git_core.lua` (git CLI wrapper + parsers),
`wavestorm_git/git_ui.lua` (dialogs),
`wavestorm_git/tests/test_git_core.lua` (tests, plain Lua, no editor needed).

## License

MIT — see [LICENSE.md](LICENSE.md).
