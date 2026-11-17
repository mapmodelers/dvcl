# Changelog

Versions follow [semver](https://semver.org). Tags: `vX.Y.Z`.

## 0.25.0 - 2026-11-17

- First run on a new PC: dvcl asks for your Diversion workspace (lists the ones found on the PC, or Browse) and checks it with Diversion before using it. A folder Diversion does not know is refused instead of being scanned (a new PC could hang on "Scanning folder": the user folder's .diversion settings folder was taken for a workspace). Repo... opens the same choice.
- install.cmd says when the Diversion dv command is missing and opens dvcl at the end. README: install steps.

## 0.24.1 - 2026-11-17

- Unreal link installed as an installed engine plugin (Engine\Plugins\Marketplace\DvclLink, prebuilt, on by default): in Engine\Plugins it broke C++ project builds. Tools > Unreal link shows "old place" and Update moves it. tests\check-build.ps1 builds a project's editor target to check.

## 0.24.0 - 2026-11-16

- Stay offline (Tools, on by default): sync is on only during an action (submit, shelve, revert, unshelve, get latest) and never left on. A dvcl that stopped while online (killed, crashed), sync on for more than 30 min, or sync turned on elsewhere: the window pauses it within 15 s, any dvcl command pauses it first. "Go online" is hidden while it is on. Command line: `dvcl safety on|off`.
- Command line: `dvcl submit` works offline (online for the submit only, then offline again, as the window does); `dvcl shelf delete <shelf>`.

## 0.23.1 - 2026-11-16

- Fix: the window could freeze while files changed a lot (every file event went through the window). The folder watcher now filters events on its own thread; the window only asks once a second whether something changed, and refreshes at most every 10 s. The log says which file triggered a refresh.

## 0.23.0 - 2026-11-16

- Up to date by itself: files saved, added, deleted or renamed in the workspace (Unreal, Explorer) refresh the list 2 s after the last change, in the background: no lock, the tree is redrawn only if the list changed. Unreal's busy folders (Saved, Intermediate, DerivedDataCache) are left out.
- Icons in grey; only the state badge is colored.
- Icon legend: hover the Changelists tab (no header row above the list).

## 0.22.0 - 2026-11-16

- Changelists easier to read: one text grey for every file (no color per state; the icon shows it), file name first with its folder after in a dimmer grey (full path in the tooltip), changelist counts dimmer, a little more space between rows.
- Clearer state icons: page with a folded corner, colored badge with a dark ring (green + added, blue dot modified, red x deleted, orange arrow renamed).

## 0.21.0 - 2026-11-16

- OFPA files (Unreal one-file-per-actor, __ExternalActors__ / __ExternalObjects__): one line per level in changelists and shelves, with the file count by kind. Click, Ctrl / Shift+click, drag, move, revert, shelve, submit and unshelve act on all its files. View > "OFPA files: one line per level" (on by default, remembered).

## 0.20.1 - 2026-11-15

- Marked experimental (window title, tray, README, site), with a feedback link (GitHub issues).

## 0.20.0 - 2026-11-15

- Tools > Unreal link: shows the engine, whether the dvcl link plugin is installed and up to date, and whether the open editor answers. Install / Update from there (builds it for the engine with progress in the state bar, Unreal closed). The engine is remembered from the last time Unreal was open, or chosen by hand.

## 0.19.0 - 2026-11-14

- No popup, no lock screen: an action shows in the state bar with its current step (steps in the log). The window keeps working while Diversion and Unreal answer (repaint, scroll, browse the trees, panels and log); only other actions are refused until it is done (toolbar off, menus and drops say wait).
- The window remembers how it was: place, size, maximized, panels, theme, open shelves and closed changelists. Saved within 3 s of a change, so an update or a crash keeps it.

## 0.18.0 - 2026-11-14

- Action popup: a small window over dvcl, which stays visible behind it but locked, instead of covering it.
- Faster: revert uses the list Diversion gave when going online (no second sync wait); after an unshelve of the whole shelf, going offline reuses the sync wait just done.

## 0.17.1 - 2026-11-14

- Unshelve from Diversion waits until Diversion reports its sync done (files on disk) instead of a fixed 3 s pause, so Unreal always reloads the new versions. Files Unreal had loaded are also compared by content.

## 0.17.0 - 2026-11-14

- Faster actions: no extra Diversion calls while an action runs (shelf list and branch head read once after it); Unreal reloads only the files whose content changed (a partial unshelve no longer reloads the whole shelf); right after dvcl pauses sync, the pending list comes from Diversion instead of a full folder scan.

## 0.16.0 - 2026-11-14

- Actions (unshelve, revert, shelve, submit, get latest, delete shelf, online / offline) run under one card over the window: the window is locked meanwhile (no misclick, no second action, no shortcut keys), the card shows each step as it runs, and the window is drawn once when the action is done (no more jumping).

## 0.15.0 - 2026-11-14

- Unreal link 3: levels used as level instances (Unreal loads them as a temporary copy under another name) are let go of and the instances reload, so unshelve / revert of such a level works with Unreal open. Update once: close Unreal, ue\install.cmd, open Unreal.
- Unreal reloads right after the files are written, before sync is paused again (shorter time with assets released).
- ue\install.cmd finds the engine with Unreal closed too (Epic launcher list).
- tests\diag-hold.ps1: which program holds a file, and what Unreal loaded under its name (read-only).

## 0.14.1 - 2026-11-14

- Unshelve asks about overwriting before Unreal lets go of the files (answering No left them released, not reloaded). If a file stays held, Unreal takes back the ones it let go of.

## 0.14.0 - 2026-11-14

- Unreal link: revert, unshelve and get latest no longer need Unreal closed or restarted. dvcl asks the open editor to let go of the files, writes them, then the editor reloads them (as Unreal's own revision control does). Assets with unsaved changes in Unreal stop the action, nothing changed. Needs the dvcl link plugin once: ue\install.cmd (builds it for your engine), then restart Unreal once.
- Shelf menu: "Move N checked-out file(s) from #X to #Y" when shelved files are checked out in another changelist (the clicked / selected shelved files, else the whole shelf; one line per changelist).

## 0.13.1 - 2026-11-14

- Revert / unshelve check first whether Unreal (or any program) holds a file open: if so they stop at once with the list, without going online.

## 0.13.0 - 2026-11-14

- Shelves like changelists: every shelf sits under its changelist with its files listed, also offline (read once, kept). Unshelve into any changelist: right-click Unshelve into, or drag the shelf or some of its files onto a changelist; selected files only works for Diversion shelves too (the shelf's other files are left as they were).
- Shelve = Diversion shelf of the selected files or the changelist, no name to type. Diversion needs sync for it: on for this only, then off again. Same for revert and unshelve; nothing else is sent or fetched.
- Revert: no backup shelf any more (your versions are copied to .dvcl\revert-backup on this PC). Files Unreal (or any program) holds open are not touched and are reported; a file Diversion could not write is reported and stays pending (it was shown as reverted).
- Unshelve asks only when it would overwrite your own changes.

## 0.12.0 - 2026-11-13

- Submit of any size: all pending files = one Diversion commit; otherwise, beyond the command-line limit, several commits "(part i/n)", said in the output. No more "command line too long".
- Offline (sync off), add / remove match against dvcl's folder scan: wildcards work as online.
- Any text in arguments: dvcl.cmd hands its whole line to dvcl, so ( ) & , ; : - and quotes arrive as typed. `dvcl args ...` shows what dvcl received.

## 0.11.1 - 2026-11-13

- Shelved files can be selected too (click, Ctrl, Shift). Right-click: Unshelve the selected files (local shelves) or all.

## 0.11.0 - 2026-11-12

- Changelists: no more tick boxes. Select like Explorer: click, Ctrl+click, Shift+click, Ctrl+A, Esc; drag the selection onto a changelist. Clicking a changelist = all its files.
- Shelves: zipped-folder icon.
- Click on empty space: nothing selected. Trees repaint without flicker.

## 0.10.2 - 2026-11-12

- Dark theme: the selection of an unfocused tree or list is dark (was white).
- History: "Follow" no longer cut.

## 0.10.1 - 2026-11-12

- Commit files: a description starting with "A ", "M "... is no longer read as a file.
- tests\check-dv.ps1: checks dvcl's reading of a real workspace's commits (read-only).
- Screenshot: dark theme, History panel.

## 0.10.0 - 2026-11-12

- Panels you arrange: Local, Depot, Changelists, Submitted, History and Log are tabs. Drag a tab onto another panel (tabs), to a window edge, or out of the window (its own window). Right-click a tab: Move to, New window, Reset layout. Toolbar View: bring a panel to front. Layout is remembered.
- Submitted: the branch's commits, newest first (local time); commits not in your workspace yet are highlighted (Get latest). Pick one: its files. Filter, More, optional path.
- History: commits of a file or folder; follows what you select while it is on screen. File menu: show in trees, history, diff with your workspace.

## 0.9.1 - 2026-11-11

- A dvcl left running in the notification area restarts on the new version when opened after an update.
- Dark theme: dark expand arrows and path tooltips in the changelist view (no light +/- boxes).

## 0.9.0 - 2026-11-11

- Changelists have numbers (#1, #2...), never reused; existing ones get theirs on first start. Command line accepts them: `dvcl submit 12`.
- Added files show green, edited files plain white (dark) / black (light).
- Find: drop a file (from a tree, a changelist or Windows Explorer) on Local or Depot to show it there. Menus: Show in Local tree / Show in Depot tree.
- Small site: https://mapmodelers.github.io/dvcl/

## 0.8.0 - 2026-11-11

- Closing the window keeps dvcl in the notification area; click the icon to open, right-click > Exit to quit. Launching dvcl again brings back the running window (one per workspace).
- Dark theme is the default. No more light outlines: dark toolbars, menus, scrollbars, borders and title bar.

## 0.7.1 - 2026-11-11

- Offline folder scan compiled (C#, built once into %LOCALAPPDATA%\dvcl): about 10x faster; same rules, PowerShell scan kept as fallback.

## 0.7.0 - 2026-11-11

- Dark theme (toolbar: Dark / Light), remembered.
- Several users of one workspace (dvcl windows, command line, agents): every change re-reads the changelists first, so nobody's edits are overwritten; outside changes show within 2 s.
- Refresh keeps the selected and checked files.

## 0.6.1 - 2026-11-11

- Shelf rows read "Shelved files (n)" (shelf name in the tooltip).
- Shelf menu: move its files that are still pending elsewhere into its changelist.

## 0.6.0 - 2026-11-11

- Shelves belong to changelists and show under them in the main view (local or Diversion). A changelist can hold pending files, shelves, or both.
- Unshelve puts the files back into the shelf's changelist. A changelist with shelves cannot be deleted.
- Diversion shelves are listed online in the background and kept for offline display.

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
