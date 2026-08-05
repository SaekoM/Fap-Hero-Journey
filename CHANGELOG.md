# Changelog

## v0.7.4

New output support for **e-stim** devices, via [restim](https://github.com/diglet48/restim) — contributed by
a community member. If you don't use e-stim, nothing here touches you: it stays completely inert unless you
turn it on and connect.

### ⚡ Drive e-stim from your journeys
Fap Hero Journey can now stream to a running **restim** instance over its WebSocket T-code connection, so a
journey's scripts drive your e-stim session the same way they drive a stroker. The main stroke maps to
restim's position (Alpha), and multi-axis scripts map onto restim's parameters (surge, carrier frequency,
pulse, vibe channels) — and items, curses, and boss effects reach it just like every other output.

- **Connect** from Options → the restim section: point it at your restim WebSocket address and connect
  (defaults to the usual local `ws://127.0.0.1:12346/tcode`).
- **Per-axis manual levels** in a new **E-STIM DEVICE** section (Options → Device), for the parameters you'd
  rather set by hand than by script. The existing device ranges are now labelled **T-CODE DEVICE** so the
  two are easy to tell apart.
- **E-stim scripts in journeys** — authors can include dedicated e-stim parameter scripts (alpha/beta,
  volume, carrier frequency, pulse, vib…); they're detected by filename and travel with their round like any
  other axis.
- Runs **alongside** your other output — e-stim plays in parallel with a Buttplug stroker (it takes over the
  serial T-code slot, since both speak the same protocol).

Requires [restim](https://github.com/diglet48/restim) running with its WebSocket server enabled. Big thanks
to [@oleg-nasan](https://github.com/oleg-nasan) for building and testing this.

## v0.7.3

A focused quality release for **The Handy over WiFi**. If you drive a Handy directly (no Intiface), this is
a big one — startup, sync, and reliability are all dramatically better, and this time it's confirmed on real
hardware. This time I am getting it right!

### 🛠 Sync that actually lands
The device used to take several seconds to start each round and then play a beat behind the video. Now it
**starts promptly and strokes in time** with what's on screen. Round starts that once took the better part
of ten seconds are down to about one, and the old "playing a second or two late" feeling is gone — sync is
tight now.

### ▶ Smooth between rounds
Moving from one round to the next no longer leaves the device frozen until you pause/resume or open the menu
— each round picks the device back up on its own, in sync, with any boss or curse effects already baked into
the very first stroke.

### 🔌 Know it's working
- A quick **"Getting the Handy ready"** moment when a journey starts (WiFi Handy only), so the first round
  is as smooth as the rest — with a short confirmation stroke so you can feel it's live before you play.
- A new **Test** button (Options → the Handy section) sends a stroke on demand to confirm the device
  responds.
- The connection status now shows a live green **● Connected** instead of a stale "Not checked."

### 🩹 Rides out a blip
If your WiFi stutters or the device briefly drops mid-round, it now quietly **reconnects and resumes** on
its own within about a second, instead of going silent until the next scene.
