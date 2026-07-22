# Changelog

## v0.6.2.1 — Early Access

An **early-access** build. Its reason to exist is a **fix for Handy (WiFi) timing** — but it also
carries a batch of new authoring and playback features that are still being tested, so treat it as
a preview rather than a stable release. If something misbehaves, please report it.

### 🛠 Handy (WiFi) timing — fixed
If you play on a Handy over WiFi and the timing was wildly off — the device starting late, playing
seconds behind, drifting further after a powerup or a pause — this build fixes the cause. The app
was seeding the device with the **opening seconds of the script** whenever a round started partway
in or after a seek, so it starved and lagged for several seconds before catching up. It now streams
from the **current position**, and pausing/resuming **re-syncs** to the video instead of drifting.
*(This is fixed in the code but hasn't yet been confirmed on-device — feedback from Handy users is
very welcome.)*

### ◆ Checkpoint nodes
Checkpoints are now their own node you drop on the canvas between rounds, instead of a per-round
toggle — place one wherever you want a Save & Quit point. **Existing journeys convert automatically:**
any round you'd marked as a checkpoint becomes a checkpoint node in front of it. Resuming from a
checkpoint now continues straight into the next round instead of re-showing the banner.

### ⚔ Bosses can carry effects
A boss round can now also apply the full hindrance/boon effect catalog (forced, on top of its
modifiers), listed on the intro card so the player sees what's coming.

### 🎚 Readability
Two new sliders in Options → Display: **Story Text** enlarges fork, boss-intro and storyboard
prose, and **Tooltip Text** enlarges every tooltip — without resizing the rest of the UI. Long
text now wraps instead of running off the screen, tooltips included.

### 🛒 Shop exclusions
Pool-mode shops get a **Never Drawn** list, so you can keep specific items out of the random lineup.

### ⏱ Round timer
An optional countdown on the HUD showing time left in the round (Options → Display, off by default).

### 🚪 Bail Out item & 🔥 Warmup rounds
A new **Bail Out** shop item ends the current round immediately for no reward (marked on your route).
And rounds can be flagged **Warmup** — the player gets a free skip button, but completing them still
pays out normally. Both are ways to make openers and grind rounds optional.

### ♥ Beat-bar shapes
The beat bar's markers can be **heart / orb / diamond / star** (Options → Display), and they're
sharper and less blurry than before.

### ⚡ Faster saves & 🖱 easier canvas
Re-saving a large journey no longer re-copies every video, so it's much quicker. And in the builder
you can now **pan with the arrow keys / WASD** (or Space + drag), and a dragged-in video lands where
you're looking instead of way off in the corner.
