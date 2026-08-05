# Changelog

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
