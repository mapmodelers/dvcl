# Changelog

Versions follow [semver](https://semver.org). Tags: `vX.Y.Z`.

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
