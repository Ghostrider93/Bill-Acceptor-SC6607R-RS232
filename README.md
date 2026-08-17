# MEI SC6607R Bill Acceptor over RS232

[![Latest release](https://img.shields.io/github/v/release/Ghostrider93/Bill-Acceptor-SC6607R-RS232?label=download%20BillCounter.exe)](https://github.com/Ghostrider93/Bill-Acceptor-SC6607R-RS232/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Notes and tools for driving an **MEI / CPI CashFlow SC66** bill validator
(`SC6607R`, RS232 build, part number `252202006`) from a Windows PC over a plain
USB-to-serial adapter.

I picked one of these up without a cashbox and wanted to see what I could get out
of it. Turns out you can get quite a lot: it validates real currency, tells you
the denomination, and hands the note back, all without the cashbox fitted. The
trick for that is in [docs/CASHBOX.md](docs/CASHBOX.md).

Everything here is PowerShell plus the built in .NET `System.IO.Ports` class, so
there is nothing to install. The money counter GUI is a single C# file compiled
with the C# compiler that already ships inside Windows.

## What works

* Full two way EBDS serial link at 9600 7E1, thousands of polls with zero
  checksum errors.
* Live status decode: idling, accepting, escrowed, stacking, returning, jam,
  cheat, cashbox present, and so on.
* Real note validation. `$1`, `$5` and `$50` have all been read correctly and
  returned through a full accept and return cycle.
* Escrow control, so you decide per note whether it gets stacked or handed back.
* **Running with no cashbox installed.** See [docs/CASHBOX.md](docs/CASHBOX.md).
* A Windows money counter app that talks to the unit and keeps a running total.

## Quick start

```powershell
# 1. Sanity check the protocol code. No hardware needed, this should be all green.
.\tools\Test-EbdsLogic.ps1

# 2. Plug in the USB serial adapter and see which port it grabbed.
[System.IO.Ports.SerialPort]::GetPortNames()

# 3. Power the acceptor with 12 V, then find it.
#    This scan is safe, it polls with every denomination disabled.
.\tools\Find-BillAcceptor.ps1

# 4. Watch it idle, still accepting nothing.
.\tools\EBDS-Host.ps1 -PortName COM4 -EnableMask 0x00 -PollMs 100 -Seconds 20 -ShowRaw

# 5. Enable all denominations and feed it a note.
#    Use -OnEscrow Return if you have no cashbox fitted.
.\tools\EBDS-Host.ps1 -PortName COM4 -EnableMask 0x7F -OnEscrow Return -PollMs 100 -Seconds 120
```

Do step 4 before step 5. Confirm the link is clean and the idle status looks
sensible before you let the thing pull paper in.

### Two things that will waste your afternoon

1. **The acceptor is a slave. It transmits nothing until you poll it.** Hook up a
   terminal and wait, and you will stare at a blank screen forever.
2. **Poll every 100 ms.** At 500 ms the unit answers every single poll with a
   valid frame and zero errors, but it never leaves its power up state. It
   decides the host is missing and parks. The link looks perfect while this
   happens, which makes it very easy to misdiagnose as a wiring fault.

## Documentation

| Document | Contents |
|----------|----------|
| [docs/WIRING.md](docs/WIRING.md) | Cables, harness pinout, DB9 wiring, power supply sizing, USB adapter driver |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | EBDS frame format, checksum, every command byte and reply byte, worked examples |
| [docs/CASHBOX.md](docs/CASHBOX.md) | Running the unit with no cashbox, and the full trail of what did not work |
| [docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md) | LED codes, coupon configuration, the USB service port, troubleshooting |
| [BillCounter/README.md](BillCounter/README.md) | The money counter app |

## Repo contents

```
tools/                 PowerShell scripts for talking to the acceptor
  Find-BillAcceptor.ps1  Sweep every COM port and report where it answers
  EBDS-Host.ps1          The main polling host. Decodes status, handles escrow
  Watch-Serial.ps1       Passive hex dump listener, never transmits
  Send-Serial.ps1        Send arbitrary hex, dump the reply
  Test-EbdsLogic.ps1     Offline self test of the framing and decode logic
BillCounter/           C# WinForms money counter, plus its build script
docs/                  Everything I worked out about this unit
```

The compiled `BillCounter.exe` is attached to the
[latest release](../../releases/latest) so you do not have to build it.

## Hardware you need

* The acceptor, obviously. RS232 build, the `R` suffix matters.
* A **12 V DC supply**. It is not USB powered. Budget for around 70 W peak while
  stacking, so a 12 V 5 A brick is a sensible bench choice.
* A **USB to RS232 adapter** giving true RS232 levels. Do not use a TTL adapter
  on an `R` unit. Mine is a
  [UGREEN DB9 male, PL2303 chipset](https://www.amazon.com/dp/B00QUZY4UG),
  which needs a driver installed on Windows 10.
* A **DB9 female to screw terminal breakout**, unless your adapter has a female
  end already.
* The 12 pin harness, or wires pushed into the connector.

Details and the pinout are in [docs/WIRING.md](docs/WIRING.md).

## This unit

Reported by the acceptor itself once it finishes booting: model byte `0x54` or
`0x55`, revision byte `0x23`. During power up it briefly reports a different
revision, so only trust these values after it reaches idling.

The rear label reads `SC6607R (RS232)`, part number `252202006`.

## License

MIT. See [LICENSE](LICENSE).

Nothing here is affiliated with or endorsed by MEI, CPI or Crane Payment
Innovations. Vendor manuals are deliberately not included in this repo.
