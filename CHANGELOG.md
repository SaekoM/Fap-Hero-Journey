# Changelog

## v0.7.0

Another feature build, mostly for storyboards and authoring. The headline is a proper **visual-novel
cast system**; alongside it are custom items, player-facing counters, an early-finish button,
auto-advance, storyboard audio, and a pile of builder quality-of-life.

### 🎭 Storyboard characters (a VN cast)
Storyboards can now show **character portraits** over the background, visual-novel style, instead of one
full-screen image. In the new **CAST** section you define a character once, give them **several portraits**
(expressions — neutral, happy, angry, whatever), and lay out **their own positions** on a drag-and-resize
preview so art of any size sits right. Then, per dialogue line, you put characters **on stage** and pick
each one's expression and spot. Two characters can share the stage (left + right), the **speaker is lit
while the others dim**, and clicking a character's name chip drops them in and marks them speaking — so a
back-and-forth is one click per line. Portraits can be animated.

### 🎒 Custom items
Define **journey-specific items** in the builder that bundle tuned effects (stroke tweaks, score/coin
multipliers, sensory effects, one-shot coin tolls/interest, and more), or act as **keys** that unlock a
fork path. They appear in the shop/item dropdowns like any built-in item.

### 🔢 Counters & counter-gated forks
Journeys can track **named counters** (belt notches, arousal, satisfied partners — whatever you invent):
bump them from rounds, storyboards, or fork choices, and **show them to the player** (a pop when they
change + a list in the inventory panel). Conditional forks can **gate on a counter**, and each choice can
require a **different** one — e.g. one path needs `prod ≥ 2`, another `test ≥ 3`. Counters are awarded when
you **finish** a round/storyboard, so you see them tick up.

### 🏁 FINISH ("I came") button
An opt-in, always-available **hold-to-confirm button** that ends the run early — optionally into an
**aftercare sequence** (say a "you lose" storyboard into a gentle round) before the end screen. Enable it
per journey, and pick the aftercare start node (or right-click a node → Set as Finish).

### ⏭ Auto-advance & 🔊 storyboard audio
Storyboards, forks, and shops can **auto-advance on a timer** (journey opt-in) so a player can't linger to
rest. And storyboards gain **audio**: an optional clip per dialogue line and per fork choice, plus an
**overarching BGM** that loops under the whole storyboard — each with its own volume.

### 🎲 Encounters & 🕹 device
Encounter (pool) rounds can be set to **not repeat** a clip until the pool is exhausted. And there's a new
opt-in **serial (T-code) stroke smoothing** for OSR2/SR6 that streams interpolated motion for smoother
strokes (Options → Device Routing). *(Serial smoothing still needs on-device confirmation — feedback
welcome.)*

### ✂ Clip editor & 🖼 cover images
The clip editor is now a roomier **two-column layout** with draggable dividers. And a journey's **cover
image must now be set explicitly** — a file named `cover.*`; the app no longer borrows whatever image it
finds first, so if a cover went missing, add one in the Journey Info panel.

### 🗂 Quality of life
- **File pickers reopen the last folder** you browsed, instead of starting over each time.
- Pooled media files keep a **readable name** now (e.g. `MyClip__…`), so a journey's `content/` folder is
  browsable instead of a wall of hashes. *(Existing journeys get readable names as you re-save with the
  original sources.)*
- Smaller: storyboards must have at least one line to save, per-type node numbering, longer coin/item
  pop-ups, and pasted content lands in view.

## v0.6.2.1

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
