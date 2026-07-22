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

## v0.6.2

Another big release. Rounds get a **real clip editor** — cut, repeat and rearrange
a video without leaving FHJ. Images can move. Journeys can count things. And the Handy's delay
slider actually works again.

### ✂ The clip editor — cut, repeat, rearrange
Open a round's **📈 PREVIEW & CUT** and you get one window with everything: the stroke curve, the video, and a **timeline** of the cut.

- **Build it from segments.** Mark ⟦IN⟧ and ⟧OUT⟧ at the playhead, hit **+ ADD**, and that window becomes a row. Add as many as you like.
- **Repeat a section.** Select a row, set a count, hit **⧉ REPEAT** — a great way to stretch out a favourite few seconds. There's no cap; it's your bake time.
- **Reorder and cut.** Move rows up and down, delete the parts you don't want. The round plays them back to back.
- **▶ PLAY TIMELINE** previews the whole assembled cut before you commit, and **Ctrl+Z / Ctrl+Y** undo inside the editor.

Everything is baked when you save, so playback is completely normal — the round just *is* the cut you built. Heads up though! Once it's saved it becomes a single mp4. Those edited sections won't be available anymore.

### 🎛 See your modifiers before you test
The same window now previews what a round will actually feel like:

- **Stroke modifiers** (boss/curse/boon scale and clamp) draw over the curve, and you can drag their strength live.
- **Sensory effects** — murk, tunnel, strobe, the colour and blur effects, and the audio ones — now run **on the preview video itself**. Drag an intensity slider and see and hear it change, instead of test-playing the round after every tweak.

### 🖼 Images that move
Boss portraits, storyboard backgrounds and fork cards accept **animated** sources — GIF, MP4, WebM and AV1. They're converted and looped automatically when you save. Sources longer than 60 seconds are trimmed, and the save tells you which ones. No audio is brought over.

### 🔢 Counters
Journeys can now count things — belt notches, drinks, partners, whatever you like. Any round or fork choice can add to a counter, and **conditional forks can branch on the total**. Mark a counter as shown and players get a little pop when it changes, plus a running tally in their inventory.

### 🎚 Sensory strength (Options → Display)
The visual and audio effects were harsher than most people wanted. There's now a **strength slider**, and it starts at **50%** — turn it up if you liked them as they were.

### ✦ Rewards you can actually see
Coins and items used to arrive in silence. Earning coins or being handed an item now pops on screen, so you know it happened.

### 🐛 Fixes
- **The Handy's delay slider did nothing** for most people. Setting a delay before a round started had it silently thrown away. This issue should now be properly addressed.
- **Number fields lost your edit** unless you pressed Enter. Typing a value and clicking away now keeps it.
- **The updater now verifies downloads.** A corrupted or mismatched download is rejected instead of being installed.
- **Item pickers show what items do.** Hover any item in a shop, reward or fork requirement list for its description, price and duration.

### 🔖 Under the hood
Journeys now carry a permanent ID, which lays the groundwork for optional add-on content built on top of an existing journey. Nothing to do — journeys saved from this version onward get one automatically.
