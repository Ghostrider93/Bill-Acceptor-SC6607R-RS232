# Running an SC66 with no cashbox

This is the part I actually wanted to write down, because I could not find it
anywhere online. Every service document says the same thing, that the cashbox
must be fitted for the unit to accept notes, and there is no bypass in the
protocol. Both of those are true, and it still works anyway.

## The short version

**Flash light at the optical receiver in the cashbox bay while the unit boots.**
Point light at the receiver and switch it on and off a few times during the
startup cycle. Not steady light, flashing.

With that done the unit:

* clears PowerUp instead of timing out at 19 seconds,
* reaches `Idling` with `CassettePresent` set,
* does not raise the no cashbox alarm,
* accepts, validates and returns real notes normally.

Verified with `$1`, `$5` and `$50`, all recognised through a full
`Accepting` to `Escrowed` to `Returning` to `Returned` cycle, over thousands of
polls with zero checksum errors.

### Steady light is not enough

This is the part that took the longest to pin down, because steady light looks
like it is working:

| What you do during boot | `CassettePresent` | Result |
|-------------------------|-------------------|--------|
| Nothing | Not set | Times out at 19 s, amber, no cashbox |
| Hold a steady light on the receiver | **Set** | **Still goes into error** |
| **Flash the light on and off a few times** | **Set** | **No alarm, unit works** |

So the presence bit and the alarm are two separate checks. A steady beam
satisfies presence and fails whatever the second check is. Only a changing signal
gets you through both.

That also explains why a phone works. You are holding it by hand near the
sensors, so the light is never really steady.

### The timing window is during boot only

Once it has finished booting and gone into the no cashbox error, you cannot talk
your way back in:

* Point the light at the receiver after the fault, and `CassettePresent` comes
  back on, but the unit stays in error.
* Flashing it after the fault does not clear the error either.

If you miss the window, cut the power and start again.

## Getting light onto the receiver

A **fiber optic cable** is the tool that made this repeatable. Feed one end at
the receiver in the bay and you can flash the other end by hand, well clear of
the mechanism, without trying to aim anything into a slot.

The emitter and receiver sit in the bay side walls, one per side, emitter on the
left and receiver on the right.

## Rules once it is running

* **Run with `-OnEscrow Return`.** With no cashbox fitted, a stack command drives
  the note into an empty bay. See the stacking section below for what happens if
  you try it anyway.
* **Any reset back into PowerUp needs the flashing again.** If it drops back to
  power up, you are starting from scratch.

## Stacking still does not work

Reading and returning notes is solved. Keeping them is not.

| Setup | What happens |
|-------|--------------|
| Set to keep the note, no light at the receiver | Takes the note, then errors out with no cashbox |
| Set to keep the note, light at the receiver | Shows `CassettePresent`, still errors |

So the check is not a one time thing at boot. It runs again during the stack
cycle, and having the beam merely lit is not enough there either.

## What the sensor is probably doing

Putting the boot behaviour and the stacking behaviour together, the most likely
explanation is that this is a **motion or position sensor, not a presence
sensor.**

The reasoning:

* Steady beam is rejected, changing beam is accepted. That is what you would
  expect if the firmware is looking for transitions rather than a level.
* The chassis carries one half of a drive coupling, a black compound gear. The
  cashbox carries the other half, an exposed metal gear train across its
  insertion face.
* The firmware drives that gear train on boot and again when stacking a note.

So the cashbox very likely carries a **slotted wheel or a window that chops the
beam** as the mechanism turns. The firmware drives the motor and counts the
resulting pulses to confirm the mechanism actually moved. No cashbox means no
chopper, which means a constant beam, which reads as a stalled mechanism, which
is the error.

Flashing by hand fakes those pulses well enough to get through the boot check.
It clearly does not fake them well enough for the stack cycle, where the timing
against the motor almost certainly matters.

**This is a theory, not a confirmed finding.** It fits everything observed so
far, but I have not yet put a scope on the receiver, and I have never seen a real
cashbox turn in this unit to compare against. Treat the pulse count, the pattern
and the timing as completely unknown.

```powershell
.\tools\EBDS-Host.ps1 -PortName COM4 -EnableMask 0x7F -OnEscrow Return -PollMs 100 -Seconds 120
```

## How to tell it worked

Watch reply byte 1 bit 4, `CassettePresent`. The pass condition is:

**byte 1 bit 4 set, byte 0 showing `Idling`, and no error.**

All three matter. **`CassettePresent` on its own does not mean you succeeded.**
Steady light will set that bit and leave the unit in error, which is exactly the
trap described above. Check the LED as well as the status byte.

Without any light you get `Idling` with byte 1 at `0x00` and a steady amber LED,
which is diagnostic code 5, cashbox removed or not home. When it has genuinely
worked you get byte 1 at `0x10`, a green LED, and notes go through.

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
  on the left, receiver on the right. These are what the flashing is talking to.

On power up the firmware runs the stacker home cycle and looks for confirmation
that the mechanism actually moved. With no cashbox there is nothing to chop the
beam, so no confirmation arrives and it faults. Give it a changing signal and it
carries on. See [What the sensor is probably doing](#what-the-sensor-is-probably-doing)
for why a changing signal and not just any signal.

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

Two more half wrong theories worth recording, because the truth turned out to sit
between them.

I first assumed the sensor pair had to be **carrier modulated**, on the reasoning
that any sensible optical sensor rejects ambient light, so a plain DC source could
never satisfy it. That is wrong at the hardware level. The detector responds fine
to plain unmodulated light, and you can prove it by holding a steady source on the
receiver and watching `CassettePresent` come on.

But it was right about one thing, and I dismissed it too early. The firmware does
want a **changing** signal, just not a carrier. Slow hand flashing is enough. If I
had taken the modulation idea seriously and tried pulsing by hand at that point
instead of switching to steady sources, this would have been solved much sooner.

I also tried the opposite, blocking the beam with opaque tape on the theory that
the cashbox occludes it. Wrong in that form. It needs to see light change, not
simply lose it.

### A discrete IR LED

Tried an ordinary IR LED with a series resistor off the 12 V rail. It did not
work steady, which now makes sense, and **it did not work flashed either**, which
is the more interesting result. The same flashing that works through a fiber
optic cable fails with the LED.

I do not have an explanation for that yet. Candidates worth testing:

* Aim and intensity. The receiver sits at an angle in the moulding, and the fiber
  puts light exactly where it needs to go while a loose LED does not.
* Wavelength. The LED I used may not match what the receiver is tuned for.
* Swamping. Too much light spilling around the bay could hold the receiver on
  even between flashes, which would turn the flashes back into a steady signal
  from the firmware's point of view.

The fiber optic cable is the reliable method for now.

## Still open

### A soldered jumper will probably not work

I spent a while planning to solder a permanent jumper across the two pin
receiver, on the theory that a short would look like a permanently satisfied
sensor. **The steady versus flashing result argues strongly against that.**

A dead short is the most steady signal you can possibly give it. Steady is
exactly the case that sets `CassettePresent` and then errors anyway. So a static
jumper, a static resistor, or a static LED should all fail for the same reason,
and the LED already has.

If you want a permanent hands free bypass, it needs to **oscillate**, not sit
still. A 555 or a small microcontroller driving the receiver line or an emitter
is the shape of the answer. The open question is what it should output.

### What to work out next

1. **Scope the receiver line with a real cashbox fitted.** This is the one
   measurement that would settle everything. Capture the waveform during boot and
   during a stack cycle and the pattern stops being guesswork.
2. **Count the pulses.** Try a fixed number of flashes during boot, two, three,
   five, and find out whether the count matters or only the fact that it changed.
3. **Work out the stack cycle timing.** Reading and returning works now, keeping
   the note does not. If the pulses have to line up with the motor, a hand
   flashed fiber will never do it and it becomes a microcontroller job triggered
   off the motor.
4. **Try other wavelengths and a tighter mount for the LED**, since the fiber
   works and the LED does not.

### Why this matters beyond the bypass

If the pulse pattern turns out to be a fixed code rather than plain motion, that
is worth knowing. The gears meshing with a slotted window would produce a
repeatable sequence, and the firmware may well be checking for that specific
sequence rather than just movement. Right now I cannot tell the difference
between "it saw motion" and "it saw the right code", because hand flashing is
sloppy enough to produce either.

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
