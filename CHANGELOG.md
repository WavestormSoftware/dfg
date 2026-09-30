# Changelog

## 2.0.0 — 2026-09-30

Full overhaul. The Git panel is now a single **non-modal, resizable window**
(Defold 1.13+) that stays open while you keep editing — no more chains of
modal dialogs.

### Added

- **Git Panel** (Project menu): one window with Status / Sync / Branches /
  History tabs. Live-updating: every action re-queries git and re-renders.
  - Status: Staged + Changes lists; per file Open / Diff / Stage / Unstage /
    Discard (confirmed); Stage all / Unstage all; commit message; Amend with
    auto-filled previous message; Commit / Commit & Push / Stage all & Commit;
    Push-after-commit checkbox; conflicts listed and block committing.
  - Sync: Push / Pull / Fetch with remote + branch pickers, ff-only option;
    results and errors inline; automatic `-u` on first push.
  - Branches: Switch, Create & switch, Delete (merged-check with force
    option), detached-HEAD/initial-repo hints.
  - History: last N commits with per-commit diff viewer.
- Robust git layer on `status --porcelain=v2 --branch -z` (NUL-separated,
  no path-quoting bugs; handles renames, unicode/spaces, unmerged states).
- Error classification with friendly messages: not a repo, empty repo,
  no upstream, no remote, merge conflicts, missing identity, network/auth,
  invalid branch name, unmerged branch delete.
- Setup / Doctor: git version, porcelain v2 support, branch/upstream,
  remotes, identity; offers `git init` for non-repos.
- Context menus: Diff / Stage / Unstage / Discard / History for File;
  Blame for Lua files. Project menu: Git Panel, Quick Commit, History,
  Setup / Doctor.
- Preferences: `default_remote`, `auto_save`, `push_after_commit`,
  `pull_ff_only`, `confirm_discard`, `history_count`.
- CI (GitHub Actions): test matrix over Lua 5.1 / 5.4 / LuaJIT.

### Changed

- Non-modal panel feature-probed; older Defold versions fall back to a
  modal variant of the same layout.
- Tests grew from 26 to 95 checks: parser fixtures captured from real git
  2.55 output + live operation tests against throwaway repos
  (stage/unstage/discard/amend/branches/push/pull/conflicts/identity).

### Removed

- The v1 modal-dialog flow and porcelain v1 regex parser (superseded).

### Fixed (v1 bugs)

- Branch classification (v1's parser mis-sorted local/remote branches).
- Crash on empty repositories (log/history now report "no commits").
- Detached HEAD handling.
- Paths with spaces/quotes/unicode in status and renames.
- Push/pull error reporting (previously raw stderr dumps).
- Panel refresh no longer wipes the commit message or checkbox state.
