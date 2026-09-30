# Wavestorm Git — editor panel for Defold

Git collaboration inside the Defold editor: status, commit, push, pull,
branches, history, diff / revert / blame per file, plus a Setup Doctor.

Pure editor-side Lua (`.editor_script` + modules) — no native code, no
bundled binaries; it shells out to the system `git`.

## Files

- `git.editor_script` — registers all `Project > Git: ...` commands plus
  `Assets / Code / Outline` file commands. Reload with
  **Project > Reload Editor Scripts** after editing.
- `git_core.lua` — git CLI wrapper (`editor.execute`, with `io.popen`
  fallback) + pure parsers for status / branches / remotes / log.
- `git_ui.lua` — `editor.ui` dialogs (commit panel, branches, push/pull,
  history, diff, doctor).
- `tests/test_git_core.lua` — parser + live-repo tests, runnable with plain
  `lua` (no editor needed).

## Commands

Project menu:

| Command | What it does |
|---|---|
| Git: Status / Commit & Push... | Main panel. Ticks files, writes message, Commit or Commit & Push. Detects conflicts + ahead/behind. Refresh loops in-dialog. |
| Git: Quick Commit... | Stage all (`git add -A`) + commit with one message. |
| Git: Push... | Push current branch to chosen remote (sets `-u` when no upstream). |
| Git: Pull... | `git pull <remote> [branch]`. Saves open files first. |
| Git: Fetch | `git fetch --all`, then shows branch/ahead/behind summary. |
| Git: History... | Last N commits (N = `wavestorm_git.history_count` pref, default 25). |
| Git: Branches... | Switch local branch or create + switch. |
| Git: Setup / Doctor... | Checks git version, repo, branch, remotes, user.name/email, .gitignore. Offers `git init` when needed. |

File context (Assets / Code / Outline):

- Git: Diff File, Git: Revert File..., Git: History for File, Git: Blame File (code files only).

## Requirements

- `git` CLI on `PATH` (checked by Setup / Doctor).
- Project must be a git working tree for most commands.
- Merge conflicts must be resolved in an external client; the panel lists
  them and blocks staging conflicted files.

## Preferences (`get_prefs_schema`)

- `wavestorm_git.default_remote` (string, `"origin"`)
- `wavestorm_git.auto_save` (boolean, `true`) — `editor.save()` before commit/push/pull/switch/revert
- `wavestorm_git.push_after_commit` (boolean, `false`) — pre-tick "Push after commit"
- `wavestorm_git.history_count` (integer, `25`)

## Behaviour notes

- Read-only git calls use `reload_resources = false` (no editor resync);
  mutating calls reload so the Assets view refreshes.
- `active()` callbacks never call git (immediate UI context); all git work
  happens in `run()` (long-running context).
- Full output is printed to the editor console; dialogs truncate at ~20k chars.
- Defold build output (`/build`, `/.internal`) is already in the project
  `.gitignore`. Large binaries should use Git LFS.

## Testing

```sh
lua wavestorm_git/tests/test_git_core.lua
```

## Distributing as a library

Add this repo as a Defold library dependency (see root README), or copy the
whole `wavestorm_git/` folder into another project (it has no native
dependencies). Editor scripts are picked up automatically. No
`ext.manifest` / bundled binaries are needed since we shell out to the
system `git`.
