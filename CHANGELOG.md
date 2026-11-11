# Changelog

Versions follow [semver](https://semver.org). Tags: `vX.Y.Z`.

## 0.5.2 - 2026-11-11

- Fix: Shelves dialog failed with two or more local shelves.
- README shorter, new screenshot (made by tests/screenshot.ps1 from a demo project).

## 0.5.1 - 2026-11-10

- Faster launch offline: Diversion is not asked (its first answer took ~20 s); branch and commit come from the last online read.
- Depot list saved per commit: no dv ls (15-40 s) while the commit is the same; when it changes, it loads without locking the window.

## 0.5.0 - 2026-11-10

- State bar: OFFLINE / ONLINE / BUSY / NO DIVERSION, one switch button, branch state.
- Submit, get latest, revert, locks: go online alone, then back offline.
- Window locked with progress while loading or working.
- Local | Depot | Changelists side by side. Depot list cached per commit.
- State icons + legend.
- Ctrl+Shift+S: show in Explorer.
- Shorter texts.

## 0.4.0 - 2026-11-10

- Faster start: the window opens at once; Diversion status and the depot list load in the background. The status no longer waits for Diversion to finish syncing (it updates by itself until sync is done). Submit, shelve and revert still wait, so they work on the complete list.
- Get latest shows when the branch has new commits.
- Locks: lock / unlock from any tree, Locks list. Command line: `lock`, `unlock`, `locks`.
- Per-folder download (Diversion selective sync) from the Local / Depot trees; folders not on this PC show greyed. Command line: `folder on|off`.
- Log panel shows actions and errors only. Long changelists list their first 1500 files.
- Offline mode: Sync > Go offline pauses Diversion sync; dvcl records the folder and finds your edits by scanning it (honours .dvignore). Changelists keep working; shelve makes a local copy (.dvcl\shelves, unshelve from Shelves). Submit, revert, get latest and locks go online for that action only (dvcl waits for the upload), then back offline. Also used when Diversion does not answer.

## 0.3.0 - 2026-11-10

- One window: Local and Depot trees next to the pending changelists.
- Path bar on each tree: paste a path, Enter goes to it. Copy, Explorer.
- Drag a file or folder from the trees onto a changelist to move its pending files.
- Get latest. Sync menu: resume / pause. Yellow bar while sync is paused.
- Changelist entries are never dropped automatically. Entries no longer pending show greyed; remove them from the changelist menu or Tools.
- Fix: 0.2 emptied changelists while Diversion sync was paused. Tools > Recover entries lost by dvcl 0.2 restores them (`dvcl recover`).
- File history (last 50 commits).
- Command line: `get`, `sync on|off`, `clean`, `recover`, `history`.

## 0.2.0

- Local and Depot trees, multi-select, installer, update, bug report.

## 0.1.0

- Changelists for Diversion: command line and interface.
