# Changelog

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
