# HandleScreens

Control the brightness of external monitors from the command line, over
DDC/CI, on Windows - from WSL or from Windows itself.

```
$ brightness list
#   Model               Mfr  Serial          Display       Resolution Position   Brightness
1   HP 23xi             HWP  3CM3450QXW      \\.\DISPLAY6  1920x1080  -1920,0    30%
2*  MSI MP273A          MSI  PB4HE25700056   \\.\DISPLAY5  1920x1080  0,0        16%
* primary display.  Run "brightness identify" to see the numbers on the screens.

$ brightness adjust -10%
#1 HP 23xi: 30% -> 27%
#2 MSI MP273A: 16% -> 14%
```

## What it does

- **Lists and recognises monitors**: real model, manufacturer and serial from
  the monitor's EDID (not Windows' "Generic PnP Monitor"), numbered left to
  right; `identify` shows each number on its screen.
- **Reads** the current brightness of one or all monitors.
- **Sets** a brightness.
- **Adjusts** all (or one) monitors by percentage points or proportionally.
- **Checks** that DDC/CI is enabled and that writes are really applied.

It changes the monitor's real backlight through DDC/CI, the same setting as
the monitor's own menu buttons, rather than darkening the image in software.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in; nothing to install).
- Monitors with **DDC/CI enabled** in their on-screen menu (often off by default).
- A video path that carries DDC: a direct DisplayPort/HDMI cable works;
  DisplayLink adapters and some docks do not.
- Optional: WSL, to run it as `brightness` from a Linux shell.

## Install

From WSL:

```
git clone git@github.com:VennittiAndrea/HandleScreens.git ~/tools/HandleScreens
ln -s ~/tools/HandleScreens/brightness ~/.local/bin/brightness
brightness check
```

From Windows only, clone anywhere and call the script directly:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\to\HandleScreens\brightness.ps1 list
```

`-ExecutionPolicy Bypass` applies to that one process; it is needed because
the script is not signed. The same command line works in a desktop shortcut or
a hotkey tool. When the clone lives inside WSL, use its
`\\wsl.localhost\<distro>\...` path instead (Windows then needs WSL to start).

## Usage

```
brightness [list]                         monitors, identity, DDC/CI state, brightness
brightness identify [seconds]             show each monitor's number on its screen (default 3)
brightness get [monitor]                  current brightness
brightness set [monitor] <0-100>          set brightness
brightness adjust [monitor] <+N|-N>       change by N percentage points   (30% -10  -> 20%)
brightness adjust [monitor] <+N%|-N%>     change by N% of the current value (30% -10% -> 27%)
brightness check [monitor] [--write]      verify DDC/CI; --write also proves a write is applied
brightness help
```

`[monitor]` is the number from `list`, `all` (default), or part of the
monitor's model, manufacturer, serial or `\\.\DISPLAYn` name, e.g.
`brightness set hp 40`.

The proportional form `-N%` keeps the ratio between monitors set to different
levels, so two different models that look alike at 30% and 16% still look
alike after the change.

`check --write` moves brightness one step, reads it back and restores it: some
monitors accept a write and ignore it. Neither `check` nor any other command
reads the monitors' capability strings, the DDC/CI probe that can crash
Windows on a few monitors with malformed strings.

Exit status: `0` success, `1` a monitor operation failed, `2` usage error.

## How it works

WSL2 has no access to the GPU's I2C buses, so the `brightness` bash wrapper
runs `brightness.ps1` in Windows PowerShell, which uses the Win32 monitor
configuration API in `dxva2.dll` (VCP feature `0x10`, brightness).

| File | Role |
|---|---|
| `brightness` | WSL wrapper: runs PowerShell, strips CRLF, returns its exit code |
| `brightness.ps1` | Commands, output, per-monitor error handling |
| `lib/Display.ps1` | Win32 interop: enumerate displays, DDC/CI handles, VCP read/write with retry, EDID names from WMI |
| `lib/Logic.ps1` | Pure logic: argument parsing, percent arithmetic, monitor matching |
| `lib/Overlay.ps1` | The `identify` windows |

Each run takes about 1.5-2 s, mostly PowerShell start-up.

## Tests

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '$(wslpath -w tests)' -EnableExit"
shellcheck brightness
```

The tests use Pester 3.4 syntax, the version bundled with Windows PowerShell 5.1.

## Limits

- A laptop's built-in panel is controlled through WMI, not DDC/CI, and is not handled.
- Monitors that cannot be reached over DDC/CI are reported by `check`; software cannot
  tell "DDC/CI off in the menu" from "the cable or dock does not carry it".
- In display clone mode, monitor names may be paired with the wrong handle.
