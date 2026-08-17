# Bill Counter

A small Windows app that talks to the acceptor and counts money.

Single C# file, WinForms, no dependencies. It compiles with the C# compiler that
already ships inside Windows, so there is nothing to install and no Visual Studio
needed.

Grab the built exe from the [latest release](../../releases/latest), or build it
yourself with `build.cmd`.

## What it does

* Connects to the acceptor on a COM port and polls it at 100 ms.
* Shows a running total in big type, plus a per denomination breakdown.
* **Return notes after counting** checkbox. Leave it ticked if you have no
  cashbox fitted, otherwise a stack command drives the note into an empty bay.
  Untick it to actually keep the notes.
* **Alerts on a rejected note.** The screen flashes red, a banner reads
  `!! BILL NOT READ !!`, and it plays an error beep. The **Sound** checkbox turns
  the beep off. Same treatment for a cheat attempt.
* Jam and stacker full both get logged and flash the screen.
* **Target amount.** Type in an amount and it tracks how much is still needed,
  which is handy as a change due readout.
* Session stats: notes counted, acceptance rate, largest note.
* **Reset** clears the session.
* **Save CSV** writes the session out to a timestamped file.
* Live log of every state change, so you can see what the acceptor is doing.

## Build

```
build.cmd
```

That runs:

```
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /optimize+ ...
```

The compiler path is hard coded to the .NET Framework 4 one, which is present on
every Windows 10 and 11 install.

## Notes

* **Only one program can hold the COM port.** If the app is connected, the
  PowerShell scripts in `tools/` will fail with
  `Access to the port 'COM4' is denied`. Disconnect first.
* Status bits like rejected and cheated stay set for several consecutive polls,
  so the app edge triggers on them. Without that you count one rejection several
  times over and the acceptance rate comes out wrong.
* The denomination table is the standard US set. If your unit has a different
  bill set, the indexes will not line up. See
  [../docs/PROTOCOL.md](../docs/PROTOCOL.md).
