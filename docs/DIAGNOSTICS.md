# Diagnostics, LEDs and service modes

## The three LEDs on the acceptor

Positions are **green on the left, yellow in the centre, red on the right**.

| Green | Yellow | Red | Meaning | What to do |
|-------|--------|-----|---------|------------|
| Solid | Off | Off | Normal | Nothing |
| 1 flash | Off | Off | Disabled by machine interface | Fix the connection |
| Solid | Solid | Off | Normal, cleaning recommended | Swap in a clean cashbox |
| Off | Solid | Off | **Cashbox not seated or missing** | Reseat the cashbox, or see [CASHBOX.md](CASHBOX.md) |
| Off | 1 flash | Off | Poor acceptance | Clean the acceptor head |
| Off | 2 flashes | Off | Jam in the acceptor | Clear the jam |
| Off | 3 flashes | Off | Jam in the cashbox | Remove the head, clear the cashbox |
| Off | 4 flashes | 4 flashes | Cashbox cleaning required | Swap the cashbox |
| Off | 8 flashes | 8 flashes | Security timeout | Wait |
| Off | Off | Solid | Cashbox full | Empty it |
| Off | Off | 1 flash | Acceptor hardware fault | Replace the unit |
| Off | Off | 2 flashes | Interface board fault | Replace the interface board |
| Off | Off | 8 flashes | Note timeout | Wait |
| Solid | Solid | Solid | Unprogrammed unit | Program with the service tool |

Colour meanings: **red** is a hard fault needing a component replaced,
**yellow** is a soft fault you can fix at the machine, **green** is no fault.

The steady amber centre LED with no cashbox fitted is the one you will meet
first. That is the cashbox missing row.

## Bezel diagnostic codes

If you have the bezel LED wired up, faults come out as half second blinks
separated by two seconds off. Count the blinks.

| Code | Meaning |
|------|---------|
| 2 | Acceptor disabled, or waiting for the interface |
| 4 | Bill path jammed |
| 5 | Cashbox removed, or cashbox not home |
| 6 | Cassette full |
| 7 | A note acceptor component needs replacement |

## Configuration coupon

An SC66 has **no DIP switches**. Denominations, bill direction and the auxiliary
port are all set with a printed configuration coupon that you feed into the unit.
The coupon is printed in the maintenance manual and is usable if you print it
without distortion and cut it to size.

1. Fill it out with a **number 2 pencil**. All ten lines must be completed, one
   circle per line. Do not mark the back.
2. Lines 1 to 7 enable each denomination.
3. Line 8 is vouchers and barcode tickets.
4. Line 9 is Aux, which enables the second serial port for player tracking.
5. Line 10 is bill direction: one way, two way face up, or four way meaning any
   orientation.
6. Press and hold the **MMI button** for about a second. On release, green and
   yellow flash together.
7. Insert the coupon. **Green flashing rapidly means accepted, red flashing
   rapidly means rejected.** The unit returns to normal operating mode by itself.

Important interaction with the serial side: **denominations disabled by coupon
stay disabled even if you send an EBDS enable command.** The coupon overrides the
host enable mask, so if a note keeps getting rejected with the mask at `0x7F`,
suspect the coupon configuration.

Note that coupon mode needs a working transport. With no cashbox fitted the
rollers will not move and the coupon will not be read. See
[CASHBOX.md](CASHBOX.md).

## USB service port

The USB connector on the front of the acceptor module is the **PPM port**,
Portable Programming Module, used to load software into flash units.

Flash or PROM? Per the manual, PROM units carry a `P` after the model number, for
example `SC6602 P US`. Flash units do not. `SC6607R` has no `P`, so this unit is
flash and reprogrammable.

Plugged into a PC it enumerates as:

```
USB\VID_0BED&PID_0100&REV_0000
CompatibleIDs: USB\Class_FF&SubClass_00&Prot_00
ConfigManagerErrorCode 28 (no driver)
```

`VID_0BED` is MEI. `Class_FF` is vendor specific, so Windows has no inbox driver
for it.

**`PID_0100` is undocumented** as far as I can find. The published MEI USB IDs are
`1100` and `1101` for CashFlow SC "EBDS over USB", which appear as a Ports COM
class device, and `0500` for SC Advance. The PID does not change across a power
cycle, so `0100` looks like this unit's normal service port identity rather than
a transient mode.

To talk to it at all, the clean route is **Zadig into WinUSB** for raw endpoint
access. WinUSB is properly signed so you do not need to disable driver signature
enforcement. I did not take this any further, since loading firmware almost
certainly needs a signed dataset from the vendor.

Avoid the driver aggregator sites. They repackage drivers with bundled junk.

### The two interfaces are mutually exclusive

Confirmed on the bench. Entering coupon mode via the MMI button takes the unit
**off the primary RS232 EBDS interface**. Polls get no reply and the line reads as
idle framing noise. Returning to normal operating mode with USB unplugged
restores it.

Operating rule: **use one interface at a time.** Nothing is damaged when RS232
goes silent, so check the LEDs before assuming a fault.

## Serial corruption during motor activity

During one long capture, comms degraded only while the motor was running:

```
[23.7s] malformed frame: 02 08 10 00 3F 7E
[54.5s] non-standard reply type 0x10: 02 08 10 00 1C 00 03 04
[27.5s] no reply (poll #230)
```

37 of 1005 polls got no reply, and several of the "replies" were **my own
transmitted poll echoed back onto RX**, mixed in with garbage bytes. Comms had
been flawless for about 2000 consecutive polls before that and only broke down
around motor runs.

Two candidate causes, and I have not separated them:

* Motor noise coupling into the RS232 line, which is a shielding and grounding
  problem.
* The 12 V rail sagging under motor load. The SC series pulls around 70 W peak.
  An undersized supply browning out mid cycle would explain the comms dropouts
  and could also explain a failed home cycle.

Check your supply rating before chasing this as a protocol problem.

## Quick troubleshooting table

| Symptom | Likely cause |
|---------|--------------|
| No COM port appears at all | USB serial driver not bound, see [WIRING.md](WIRING.md) |
| Nothing answers on any port | TX and RX swapped, no 12 V, or wrong port |
| Answers but stuck in PowerUp forever | Polling too slowly, set `-PollMs 100` |
| Idles fine but will not take a note, steady amber | No cashbox, see [CASHBOX.md](CASHBOX.md) |
| Takes the note, then faults with no cashbox | Set to stack with no cashbox fitted. Use return instead, see [CASHBOX.md](CASHBOX.md) |
| Shows cashbox present but sits in error anyway | Steady light on the bay receiver. It has to flash, see [CASHBOX.md](CASHBOX.md) |
| Note goes in and comes straight back out | Denomination disabled by the coupon, or the note is dirty or folded |
| `Access to the port 'COM4' is denied` | Something else has the port open |
| Checksum mismatches only during motor runs | Supply sag or motor noise, see above |
