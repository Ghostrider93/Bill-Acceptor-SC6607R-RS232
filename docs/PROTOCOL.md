# EBDS protocol on the SC6607R

The SC66 series speaks **EBDS** (Enhanced Bill Document Set), the MEI serial
protocol. This page is what I confirmed against my own captured traffic, byte by
byte. Where something comes from the docs but I have not proved it on hardware, I
say so.

## Serial settings

| Setting | Value |
|---------|-------|
| Baud | 9600 |
| Data bits | 7 |
| Parity | Even |
| Stop bits | 1 |
| Flow control | None |

That is `9600 7E1`. Corroborating evidence: every byte in every frame I have
captured is `0x7F` or lower, which is exactly what you get when the eighth bit is
being eaten as parity.

## Poll rate

**Poll every 100 ms.** This one cost me real time:

| Poll interval | Result |
|---------------|--------|
| 500 ms | Replies to every poll, valid frames, zero checksum errors, but sits in PowerUp forever |
| 100 ms | Reaches Idling in about 2 seconds and holds it indefinitely |

At the slower rate the acceptor concludes the host is absent and parks in its
power up state. Nothing in the serial traffic hints at a problem, so this is easy
to blame on wiring.

## Frame format

```
HOST -> DEVICE   (8 bytes)
  02   08   1T   D0   D1   D2   03   CHK
  STX  LEN  TYP  <- data ->   ETX  CHK

DEVICE -> HOST   (11 bytes)
  02   0B   2T   D0 D1 D2 D3 D4 D5   03   CHK
  STX  LEN  TYP  <---- data ---->   ETX  CHK
```

* `LEN` is the **total** frame length, counting `STX` and `CHK`.
* `T` is the **ACK toggle**. The host alternates bit 0 on each new poll, giving
  message type `0x10` then `0x11`. The device echoes the same toggle back as
  `0x20` or `0x21`. Repeating the previous toggle asks the device to resend its
  last reply, which is how you recover from a corrupted frame without losing a
  credit.
* `CHK` is **XOR of every byte from `LEN` through the last data byte**. `STX` and
  `ETX` are not included. This is the part most implementations get wrong, and
  the part I would check first if your frames are being rejected.

### Worked checksum examples

All three verified:

```
02 08 10 7F 1C 10 03 6B      08^10^7F^1C^10           = 6B   ok
02 08 10 00 10 10 03 18      08^10^00^10^10           = 18   ok
02 0B 20 01 10 00 00 54 2A 03 44
                             0B^20^01^10^00^00^54^2A  = 44   ok
```

In PowerShell:

```powershell
function Get-EbdsChecksum {
    param([byte[]]$Bytes)
    $chk = 0
    for ($i = 1; $i -le ($Bytes.Length - 3); $i++) { $chk = $chk -bxor $Bytes[$i] }
    return [byte]($chk -band 0xFF)
}
```

## What you send: the standard omnibus command

There is really only one command you need. You send it over and over, and the
three data bytes control everything.

### Data byte 0, denomination enable mask

| Bit | Meaning |
|-----|---------|
| 0 | Enable bill type 1 |
| 1 | Enable bill type 2 |
| 2 | Enable bill type 3 |
| 3 | Enable bill type 4 |
| 4 | Enable bill type 5 |
| 5 | Enable bill type 6 |
| 6 | Enable bill type 7 |

`0x7F` accepts everything. `0x00` accepts nothing, which is what the port scanner
uses so it can poke every COM port on the machine without risk.

Worth knowing: **denominations disabled by a configuration coupon stay disabled
even if you enable them here.** The coupon wins.

### Data byte 1, control

| Bit | Meaning |
|-----|---------|
| 0 | Special interrupt mode |
| 2 | Orientation control |
| 3 | Orientation control (both set means accept all 4 orientations) |
| 4 | Escrow mode enable |
| 5 | **Stack** the note currently in escrow |
| 6 | **Return** the note currently in escrow |

`0x1C` is the sane default: all four orientations, escrow mode on.

To stack, send `0x1C | 0x20 = 0x3C`. To return, send `0x1C | 0x40 = 0x5C`. Send
that on the next poll after you see the escrow status, then drop back to `0x1C`.

### Data byte 2, reporting

| Bit | Meaning |
|-----|---------|
| 4 | Extended note reporting |

Leave this at `0x00` unless you want extended reporting, which changes the reply
format and breaks the decode below.

## What you get back

Six data bytes.

### Byte 0, transport state

| Bit | Flag |
|-----|------|
| 0 | Idling |
| 1 | Accepting |
| 2 | Escrowed |
| 3 | Stacking |
| 4 | Stacked |
| 5 | Returning |
| 6 | Returned |

### Byte 1, faults and presence

| Bit | Flag |
|-----|------|
| 0 | Cheated |
| 1 | Rejected |
| 2 | Jammed |
| 3 | Stacker full |
| 4 | **Cassette present** (cashbox fitted) |
| 5 | Paused |
| 6 | Calibration |

Bit 4 is the important one if you are working without a cashbox. See
[CASHBOX.md](CASHBOX.md).

### Byte 2, power and note value

| Bits | Meaning |
|------|---------|
| 0 | PowerUp |
| 1 | Invalid command |
| 2 | Failure |
| 3 to 5 | **Note value**, bill type index 1 to 7 |
| 6 | Transport open |

### Bytes 3, 4, 5

| Byte | Meaning |
|------|---------|
| 3 | Stalled, disabled, capability bits. Lower confidence, I log this one raw |
| 4 | Model number |
| 5 | Code revision |

Byte 3 has read a constant `0x10` on my unit in every frame so far, so I have
learned nothing from it.

### Worked reply

```
02 0B 20 01 10 00 00 54 2A 03 44
         |  |  |  |  |  |
         |  |  |  |  |  +-- revision 0x2A
         |  |  |  |  +----- model 0x54
         |  |  |  +-------- byte 3
         |  |  +----------- byte 2 = 0x00, no PowerUp, note value 0
         |  +-------------- byte 1 = 0x10, cassette present
         +----------------- byte 0 = 0x01, idling
```

Healthy, empty, idle unit with its cashbox in.

## Denomination table

Bill type index to note value. This mapping is **dataset dependent**, so verify
it on your own unit by feeding known notes one at a time and reading back the
index.

| Index | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|-------|---|---|---|---|---|---|---|
| Note | $1 | $2 | $5 | $10 | $20 | $50 | $100 |
| Status on my unit | confirmed | inferred | confirmed | seen | not yet | confirmed | not yet |

`$5` landing on index 3 rather than index 2 proves this bill set **includes `$2`**.
If it did not, everything above `$1` would have shifted down one slot. With `$1`,
`$5` and `$50` all landing where the standard US table says they should, a
mismatched dataset is ruled out.

## A typical note cycle

What you actually see, poll by poll:

```
Idling
Accepting                                   note pulled in
Escrowed, note value 3                      recognised as $5, waiting for you
Escrowed  (you send data1 = 0x5C here)      return requested
Returning
Returned
Idling
```

Swap `0x5C` for `0x3C` and you get `Stacking` then `Stacked` instead, and the
note value on the `Stacked` frame is your credit event.

Rejections look like this instead, with byte 1 bit 1 set:

```
Accepting
Rejected                                    not recognised, pushed back out
Idling
```

**Watch the edges, not the levels.** The rejected and cheated bits stay set for
several consecutive polls. If you count on the level you will count one note
several times. Track the previous value and only act on the transition.

## Sending commands by hand

`Send-Serial.ps1` will fire any hex string at the port and dump whatever comes
back. Remember the port settings, the defaults on that script are 8N1.

```powershell
# Poll with everything disabled, escrow mode on
.\tools\Send-Serial.ps1 -PortName COM4 -Baud 9600 -DataBits 7 -Parity Even -Hex "02 08 10 00 1C 00 03 04"

# Poll with everything enabled
.\tools\Send-Serial.ps1 -PortName COM4 -Baud 9600 -DataBits 7 -Parity Even -Hex "02 08 10 7F 1C 00 03 7B"
```

One hand sent poll is not enough to bring the unit out of PowerUp. You need the
sustained 100 ms cadence for that, which is what `EBDS-Host.ps1` does.

## EBDS-Host.ps1 parameters

| Parameter | Default | What it does |
|-----------|---------|--------------|
| `-PortName` | `COM1` | Serial port |
| `-EnableMask` | `0x7F` | Data byte 0, which denominations to accept |
| `-OnEscrow` | `Stack` | `Stack`, `Return` or `Hold` when a note reaches escrow |
| `-Data1Base` | `0x1C` | Base value for data byte 1 |
| `-Data2` | `0x00` | Data byte 2 |
| `-PollMs` | `200` | Poll interval. **Set this to 100** |
| `-Seconds` | `60` | Run time, then it exits on its own |
| `-ShowRaw` | off | Echo every raw frame to the console |
| `-LogFile` | none | Write the session to a file. Raw frames always go here |
| `-Denominations` | US set | Override the index to value table |

Every long running script takes `-Seconds` and exits by itself, so nothing hangs
a terminal.

## Only one program can hold the port

Obvious in hindsight, but it caught me more than once. If `BillCounter.exe` is
connected, the PowerShell scripts get `Access to the port 'COM4' is denied`.
Disconnect or close the app first.
