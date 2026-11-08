# dvcl

Changelists for [Diversion](https://diversion.dev): command line and interface.

![dvcl](docs/screenshot.png)

## Install
Download or clone this repository anywhere, then run `dvcl-gui.cmd` (window) or `dvcl.cmd` (command line)
from inside a Diversion workspace. Nothing is installed.

## Requirements
- Windows, Windows PowerShell 5.1 (built in)
- Diversion Desktop running, `dv` CLI in PATH (v1.6+)

## Window (dvcl-gui)
Run `dvcl-gui.cmd` (from inside a workspace, or it reopens the last one; **Repo...** to switch).

- Tree: `default` + your changelists, with pending files (A added, M modified, D deleted, R renamed).
- **Move files**: drag onto a changelist, or right-click > Move to. Check boxes for multi-select
  (checking a changelist checks all its files).
- **Submit...**: description + file checklist (uncheck to leave files pending). Ctrl+Enter.
- **Shelve...**: cloud shelf of a changelist, workspace untouched (also moves work to another PC).
- **Revert...**: discards local changes of checked/selected files; a backup shelf is made first.
- **Shelves**: unshelve or delete shelves. **F5** refresh, **Ctrl+N** new changelist.
- Double-click a file: show in Explorer. Double-click a changelist: edit description.

## Command line (dvcl)
```
dvcl                          list pending files by changelist (#numbers)
dvcl new <cl> [description]   dvcl desc <cl> <description>   dvcl delete <cl>
dvcl add <cl> <spec...>       dvcl remove <spec...>
dvcl submit <cl> [-y]         dvcl submit default "msg"
dvcl revert <cl> [-y]         dvcl shelve <cl>    dvcl shelves    dvcl unshelve <shelf>
dvcl report                   dvcl selftest
```
spec = `#` number or range (`4`, `5-9`), file, folder or wildcard (`Content/Maps/*`); the top folder (`MyGame/`) is optional.

## Data
Per workspace, local only: `<repo>\.dvcl\changelists.json` and `<repo>\.dvcl\dvcl.log`.
Add `/.dvcl/` to the workspace's `.dvignore`. Window settings: `%APPDATA%\dvcl\settings.json`.

## Layout
```
dvcl.cmd       -> src/dvcl-cli.ps1   command line
dvcl-gui.cmd   -> src/dvcl-gui.ps1   window (WinForms)
src/DvclCore.ps1                     shared engine (dv calls, status parser, changelist store)
```
The .ps1 files live in src/ on purpose: PowerShell would otherwise pick dvcl.ps1 over dvcl.cmd and hit the
execution policy. The .cmd launchers run PowerShell with -ExecutionPolicy Bypass.

## License
MIT. Not affiliated with Diversion.
