# Wiring and cables

## Power, read this first

The acceptor runs on **12 V DC from its own supply**. It is not USB powered and
the serial adapter will not run it.

Published draw for the SC series:

| State | Power |
|-------|-------|
| Idle | about 10 W |
| Accepting | about 30 W |
| Stacking | about 70 W peak |

Size for the stacking peak. A 12 V 5 A brick is a sensible bench choice. An
undersized supply shows up as the unit resetting part way through a cycle, which
looks like a comms fault but is not. I saw serial corruption during motor runs on
this bench, and a sagging rail is one of the two likely causes, the other being
motor noise coupling into the RS232 line.

## The 12 pin harness

Wire colours on the SC66 12 pin connector:

| Pin | Colour | Pin | Colour |
|-----|--------|-----|--------|
| 1 | White | 7 | Black |
| 2 | Gray | 8 | Purple |
| 3 | Red | 9 | Brown |
| 4 | Yellow | 10 | Orange |
| 5 | Blue | 11 | Green |
| 6 | Pink | 12 | Tan |

On the RS232 build, these are the ones that matter:

| Pin | Colour | Signal |
|-----|--------|--------|
| 5 | Blue | Logic ground |
| 6 | Pink | **RXD**, input to the acceptor |
| 7 | Black | Power minus |
| 11 | Green | Power plus, 12 V |
| 12 | Tan | **TXD**, output from the acceptor |

Pins 5 and 7 are normally tied together with a loop of wire behind the connector.

The rest of the harness, for reference: pin 1 white is external inhibit, pin 2
gray is bezel LED drive, pin 4 yellow is out of service, pin 8 purple is LED
supply.

> **Buzz it out before you apply power.** Sources agree on the wire colours but
> one source I found had the pin numbers garbled in transcription. Put a meter on
> it and confirm 12 V lands on green and black before you energise anything.

## Is it actually the RS232 build?

Check the label. Mine reads `SC6607R (RS232)`. The `R` suffix is what you want.

There is also an opto isolated EBDS build with a **completely different pinout**,
TXD and RXD on pins 9 and 10, and it will not work with a plain RS232 adapter.
An `R` unit expects true RS232 levels of plus and minus 12 V, so a standard USB
to RS232 adapter is correct. Do not feed a true RS232 adapter into a TTL or opto
level unit.

## DB9 to acceptor

Three wires, no handshake lines.

| DB9 pin on the adapter | Direction | Acceptor |
|------------------------|-----------|----------|
| 3, TX out of the PC | to | Pin 6 pink, RXD |
| 2, RX into the PC | from | Pin 12 tan, TXD |
| 5, ground | common | Pin 5 blue, logic ground |

Tie the PC ground and the 12 V supply ground together.

If nothing answers, the first thing to try is swapping pins 2 and 3. It costs
nothing and it is the most common mistake.

## The adapter I used

**UGREEN 3FT DB9 Male USB to Serial Adapter, RS232, PL2303 chipset.**
[Amazon B00QUZY4UG](https://www.amazon.com/dp/B00QUZY4UG)

It works, but plan for two things:

* The DB9 end is **male**, so it has pins, not sockets. To get from there to bare
  harness wires you want a **DB9 female to screw terminal breakout**, which is a
  couple of dollars. Otherwise you are trying to clamp wires onto pins, which is
  as bad as it sounds.
* **It needs a driver on Windows 10.** See below. Out of the box mine did not
  even get a COM number.

Any true RS232 adapter will do. This is just the one on my bench, and the driver
notes below are specific to its Prolific chip.

## USB serial adapter driver

My adapter is a **Prolific PL2303GC**, USB ID `VID_067B&PID_23A3&REV_0305`. Out
of the box on Windows 10 it sat at `CM_PROB_FAILED_INSTALL`, error code 28, with
no driver bound at all and no COM number assigned.

The reason: the driver store only had the legacy `ser2pl.inf`, which matches
`PID_2303`, not the newer G series `PID_23A3`. Windows Update could not supply
the right one either, it failed with `0x80244011` on this machine.

The fix is to install the current Prolific driver by hand:

* `PL23XX-M_LogoDriver_Setup_4900_20260306.exe`, version 4.9.0.0
* Authenticode signature valid, signed by Prolific Technology Inc. via DigiCert
* Covers PL2303 HXD, SA, RA, GC, GS, GT, GL, GE, GD and GR

Run it elevated, click through the wizard, then **unplug and replug the adapter**
so it re-enumerates and binds to the new driver. Mine came up as COM4.

This is a genuine current generation G series chip, so the counterfeit PL2303HXA
"code 10" saga you will read about does not apply. The official driver just
works.

Get the installer from Prolific directly. It is not in this repo, and the driver
aggregator sites like DriverMax and DriverScape repackage drivers with bundled
junk.

## Check which ports you have

```powershell
[System.IO.Ports.SerialPort]::GetPortNames()
```

On my machine COM1 is a real motherboard serial port and COM3 is Intel AMT serial
over LAN, which is unusable. The USB adapter shows up as a new port on top of
those. Do not assume the first port in the list is yours, just run the scanner:

```powershell
.\tools\Find-BillAcceptor.ps1
```

It sends a poll with every denomination disabled, so it is safe to point at
every port on the machine. Add `-AllSettings` if you want it to also try other
baud rates and framings.
