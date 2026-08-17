# Running an SC66 with no cashbox

This is the part I actually wanted to write down, because I could not find it
anywhere online. Every service document says the same thing, that the cashbox
must be fitted for the unit to accept notes, and there is no bypass in the
protocol. Both of those are true, and it still works anyway.

## The short version

**Shine infrared light on the optical sensor in the cashbox bay while the unit
initialises.** That is it. Once it reaches idling it latches ready and you can
take the IR source away.

A phone works. Hold the phone near the sensors in the bay during power up. Phone
front cameras and proximity sensors emit IR, and that is enough.

With that done the unit:

* clears PowerUp in about 5 seconds instead of timing out at 19,
* reaches `Idling` with `CassettePresent` set,
* accepts, validates and returns real notes normally.

Verified with `$1`, `$5` and `$50`, all recognised through a full
`Accepting` to `Escrowed` to `Returning` to `Returned` cycle, over thousands of
polls with zero checksum errors.

## Rules once it is running

* **The IR is needed during initialisation only.** After it reaches idling, take
  the phone away and it keeps running indefinitely. I have read notes cleanly
  long after the IR source was removed.
* **Any reset back into PowerUp without IR present fails to re-init.** If it
  drops back, you need the IR again.
* **Run with `-OnEscrow Return`.** With no cashbox fitted, a stack command drives
  the note into an empty bay. Hand it back instead.

```powershell
.\tools\EBDS-Host.ps1 -PortName COM4 -EnableMask 0x7F -OnEscrow Return -PollMs 100 -Seconds 120
```

## How to tell it worked

Watch reply byte 1 bit 4, `CassettePresent`. The pass condition is:

**byte 1 bit 4 set, and byte 0 showing `Idling`.**

Without the IR you get `Idling` with byte 1 at `0x00` and a steady amber LED,
which is diagnostic code 5, cashbox removed or not home. With it you get byte 1
at `0x10` and a green LED.

```
No cashbox, no IR:   02 0B 21 01 00 00 10 55 23 03 4D    idling, byte1 = 0x00
Healthy:             02 0B 20 01 10 00 00 54 2A 03 44    idling, byte1 = 0x10
```

That byte alone is how I confirmed bit 4 means cashbox present, by correlating
`0x00` against the amber fault on my unit and `0x10` against a known good unit.

## What the unit is actually doing

The cashbox itself is completely passive. I pulled the parts breakdown apart to
check, and the whole cashbox assembly is a handle kit, a stacker base, a side and
door assembly, an aperture plate, a pressure plate, a spring and a hasp. No
motor, no gears of its own beyond the driven coupling, no switch, no sensor, no
electrical connector at all. Notes get pushed through the aperture plate onto a
spring loaded pressure plate.

The rework procedure confirms the same thing from the inside. The cashbox
interior is a yellow pressure plate on two coil springs, with the stacker
assembly bolted in at the bottom behind two Pozi screws. The stacker assembly is
a translucent plastic frame carrying a metal shaft and the stacker plate, and it
is entirely passive.

So everything that senses anything lives in the chassis:

* **The motor and gear train.** The motor is in the acceptor module. The chassis
  carries one half of the drive coupling, a black compound gear. The cashbox
  carries the other half, an exposed metal gear train across its insertion face.
* **One cashbox presence switch**, part `214791027P`, mounted in the chassis and
  wired to the EBDS interface board. The box depresses it mechanically on
  insertion.
* **Two IR optical devices** set into the bay side walls, one per side. Emitter
  on the left, receiver on the right. These are what the IR trick is talking to.

On power up the firmware runs the stacker home cycle and looks for confirmation
that the mechanism is where it should be. Interrupt that confirmation and it
fails. Satisfy it, by any means, and it carries on.

## What did not work

Writing these down because I burned a lot of time on them and someone else should
not have to.

### The two switches on the interface board

`SW1` and `SW2` are silkscreened on the EBDS interface board along its bottom
edge, black microswitches with white lever actuators facing into the bay. They
look like exactly what you want. They are not.

Actuating them **does** set cashbox present, and it is repeatable:

```
[ 30.2s] CassettePresent, PowerUp     held 19.2s
[ 49.4s] Idling                       reverted
[ 66.9s] CassettePresent, PowerUp     held 19.1s
[ 86.0s] Idling                       reverted
```

But then the unit enters PowerUp, runs the stacker home cycle, and after a
consistent **19 second timeout** gives up and reverts to idling with byte 1 back
at `0x00`. Three independent measurements: 19.2 s, 19.1 s, 18.9 s. That is a
firmware timeout, not hand timing, and holding the switches closed from a cold
boot does not change it. Throughout that window byte 0 stays at `0x00`, so the
unit never reaches idling while cashbox present is asserted.

The presence check passes. The initialisation check is what fails.

**`SW2` also changes the green LED between one flash, meaning disabled by machine
interface, and solid, meaning normal.** That is an interface indication and it
has nothing to do with the cashbox state. It is very easy to see that change and
conclude you have fixed something.

### Cam driven switch sequences

I spent a while on the theory that the switches were cam actuated position
sensors and the firmware wanted a timed sequence of transitions. The parts
breakdown killed that. **The cashbox contains no switches at all**, so there is
no cam to drive them. There is exactly one presence switch and it is in the
chassis.

The manual FAQ backs this up twice. First, an SC66 has no DIP switches at all,
denominations are set by configuration coupon, so neither switch is a config
jumper. Second, the red, black and white wires go to an internally mounted switch
that reports whether a cassette is present or has been pulled, wired normally
open or normally closed depending on how you connect it. That is one SPDT
microswitch brought out to the harness for player tracking, nothing more.

### Coupon mode

I printed the configuration coupon from the maintenance manual at 100 percent
scale, filled it in per the instructions, entered coupon mode via the MMI button
and confirmed the green and yellow flashing. Then I fed it in.

**The rollers never moved.** Not accepted, not rejected, no transport at all.

That was the decisive negative result. Transport is gated by the cashbox check in
every mode, not just normal operation. At that point every software reachable
layer was eliminated:

| Layer | Result |
|-------|--------|
| EBDS command set | No bypass exists in the protocol |
| Cashbox presence switches | Satisfied, init still fails at 19 s |
| MMI coupon mode | Enters correctly, transport still dead |
| Configuration coupon | Unreadable, because transport never runs |
| USB service port | Enumerates, needs a driver and almost certainly a signed dataset |

I concluded at that point that a real cashbox was the only option. That
conclusion was wrong, but only because the answer is not a software layer at all.
It is optical.

### Modulated IR, and blocking the beam

Two more dead ends worth recording.

I assumed the sensor pair had to be modulated, on the reasoning that any sensible
optical sensor rejects ambient light, and therefore a plain DC IR source could
never satisfy it. That is wrong. The detector responds to plain unmodulated IR,
which is exactly why a phone works.

I also tried the opposite, blocking the beam with opaque tape on the theory that
the cashbox occludes it. Also wrong. It needs to **see** IR, not lose it.

### A discrete IR LED

Tried an ordinary IR LED with a series resistor off the 12 V rail and it did not
work for me, where the phone does. The likely reasons are aim and intensity,
since the sensor sits at an angle in the moulding, and there may be reflective
surfaces inside a real cashbox that the geometry depends on. This is worth
another attempt with better alignment.

## Still open

**Bridging the detector electrically.** The receiver is a two pin device, so it
is a bare photodiode or phototransistor with its load resistor on the board,
which means shorting it is current limited and safe to try. A jumper across those
two pads would make the bypass permanent with no light source at all.

I have not proved this yet. Every attempt so far was captured while the unit was
already initialised and latched, so no fresh initialisation ever happened inside
the capture window and the bridge was never actually tested.

If you want to try it, the test has to be:

1. Bridge the two pads and hold.
2. Still holding, **cut the 12 V**.
3. Wait a few seconds.
4. Power back on, still holding.
5. Keep holding another 20 seconds.

The power cycle is the step that matters. Without it the unit is still latched
from before and the result means nothing. Watch for PowerUp clearing a few
seconds after power returns.

If a dead short does nothing, try resistors across the pads instead, working down
from 100 k to 10 k to 1 k. A phototransistor in light is a resistance, not a
short, and the firmware may be looking for a value rather than a rail.

## Parts, if you would rather just buy a cashbox

The acceptor module and cashbox are interchangeable across identical SC66 models.

| Part | Number |
|------|--------|
| Stacker Base Assembly | 252063077 |
| Cashbox Handle Kit | 252062003P |
| Side and Door Assembly | 252015004P |
| Aperture Plate Assembly | 252011006P |
| Pressure Plate | 252021038P |
| Conical Spring | 252035063P |
| Hasp | 252035002P |
| Switch, Cassette Present | 214791027P |
| EBDS Interface Board Gen 1 | 252018055P |
| EBDS Interface Board Gen 2 | 252026090P1 |

Check these against a current parts guide before ordering. They came out of a
parts listing rather than a confirmed BOM for this exact unit.
