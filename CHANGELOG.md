# Changelog

## v0.7.7

A randomizer release built around long videos: one clip now yields **many different rounds**, and the wait
before **Play** collapses from minutes to about one.

### 🎬 One long video, many rounds
- The randomizer used to treat every clip as exactly one round, so a folder of 20-minute videos gave you a
  handful of enormous rounds and the same session every time. It now **cuts a long video into round-sized
  parts**, and each part becomes its own round.
- The cuts come from the **funscript, not a stopwatch**: scripters already pause at scene changes and mark
  passages by changing tempo, so a part is a self-contained passage instead of an arbitrary window. No part
  ever starts mid-stroke, and dead stretches are left out entirely.
- New **"Cut into parts"** toggle with a **Round length** range (15 s to 10 minutes, default 60–180 s).
  Harder passages tend to come out shorter.
- **Every Generate draws different cuts**, so the same folder gives you a different session each time — and
  the same seed still reproduces a run exactly.
- Clip changes now **fade video and audio** instead of hard-cutting.
- Videos **without a funscript** work exactly as before, and **presets saved earlier** keep their old
  whole-clip behaviour.

### ⚡ Play starts while the rest is still baking
- Encoding a full run took 5–10 minutes with nothing to do but wait. **Play now starts as soon as the first
  two rounds are ready** — typically 1–3 minutes — and the remaining parts keep baking in playback order
  while you play.
- The encoder is **faster than playback**, so it builds a lead during the session instead of losing one. If
  playback does catch up, the round **waits visibly and starts the moment its part is ready** rather than
  failing.
- All encoding now runs through **one queue with two priorities**, so background baking never competes with
  something you are waiting for.
- A part that cannot be baked is **skipped quietly** after one retry; the session is one round shorter.
- Note: a session left **mid-bake** cannot be resumed — quitting before a run has finished baking discards
  that run and its save on the next start. **Keep** is unaffected: it still bakes everything up front.

### 🩹 Fixes
- Importing a **long funscript no longer freezes the app** — the tempo scan grew quadratically with the
  number of actions, so a large script could stall the import for minutes.

## v0.7.6

A hotfix that smooths the round → shop → round flow and clears up a handful of visual bugs.

### 🎬 Cleaner round transitions
- Boss, effect, and mystery-encounter **intro cards now fade away to reveal the round** instead of
  hard-cutting, and they no longer show the previous round's frozen last frame behind them.
- **Shops, checkpoints, and forks** now open on a clean black background — the last frame of the round you
  just finished no longer bleeds through behind them.

### ✨ Rewards you can actually see
- Item / coin / counter **pop-ups now sit above the shop and other full-screen screens**, so a reward
  handed to you right before a shop (or storyboard) isn't buried behind it.
- Buying an item in a shop now shows a clear **"✓ added to inventory"** confirmation — the old feedback was
  a quick flash that was easy to miss.

### 🧰 For creators (builder & QC)
- **Test From Here** can now **pre-grant items and pre-set counters** for the run (alongside the existing
  score / coins / flags seeds), so a mid-journey node can be tested with the state it expects — item- and
  counter-gated forks and shops finally exercise from any starting point.
- In **test mode**, press **→** to **complete the current round instantly and still collect its rewards**
  (coins, items, counters) — QCing a long journey no longer means watching every video end to end.
- The shop's item pickers in the builder are now **compact multi-select dropdowns** — with each item's
  description on hover — instead of long checkbox columns.

### 🩹 Fixes
- **Tunnel** sensory effect: its intensity now visibly changes the strength — low is a faint vignette, high
  closes to near-black. (Before, 1% and 100% looked the same.)
- Shop: the **rightmost item card's border is no longer clipped** when a row is full.
- Builder: **⊞ ARRANGE** now moves pinned notes along with their nodes.
- The **warmup-round SKIP button now fades in with the HUD** at round start instead of popping in solid.

## v0.7.5

A creator-focused release: **two new ways to shape a journey** — Loops and map backdrops — a batch of
builder quality-of-life, and two fixes that matter in play (your saved place actually comes back, and the
Handy stays in sync through quiet stretches).

### 🔁 Loops
Wrap a stretch of your journey in a pair of markers — a **Loop Start** and a **Loop End** — and it repeats
until an exit condition is met.
- **Exit on your terms** — after a number of repeats, when a flag or item is present, or when a counter
  reaches a value (count **up to** N or **down to** N).
- **Hidden on the map by default** — loops don't clutter the in-game map unless you opt in per journey.
- **Paired for real** — deleting one marker removes its partner, ⊞ ARRANGE lays loops out cleanly, and
  forks work inside a loop.

(This replaces the old single-node "Repeat"; the wording is now **Loop** throughout.)

### 🗺 Map backdrops
Put location art *behind* your journey graph — in the builder and on the in-game map.
- **Stack layers** — combine multiple images, each with its own **opacity, scale, and rotation**, and
  reorder them with **z-order** controls.
- **Rendition-aware** — a rendition can add its own backdrops on top of the base journey's.

### 🧰 Builder quality-of-life
- **Pin sticky notes to nodes** — a pinned note follows its node and travels with it on copy / cut / paste /
  duplicate. Marquee-select notes to move or delete several at once.
- **Image fit for fork & boss art** — choose **Fit** (whole image, letterboxed), **Crop** (fill & crop), or
  **Stretch** (fill, distort). Existing journeys look exactly as before.
- **Truer fork "N ROUNDS" counts** — each choice now counts only the rounds unique to that branch and stops
  where the paths rejoin, instead of over-counting the shared tail.
- **Remove items on a node** — a node can take an item away on completion, alongside the counters and flags
  it grants.
- **Animated builder background toggle** (Options → Display) — turn the moving orbs off for a plain black
  canvas: less motion, lighter on the GPU.

### 🎮 In the run
- **Hold to exit** — leaving to the menu (ESC, or the HUD **MENU** button) now takes a brief hold, so a
  stray tap can't drop you out of a scene.
- **Checkpoint "on continue" rewards** — a checkpoint can grant an item, counters, and flags that land only
  when you **Continue** from it — not on Save & Quit, and not simply by resuming.

### 💾 Saving your place — fixed
Save in a journey and come back later, and you now **return to where you left off** instead of restarting
from the beginning. (Your coins and purchased items were already kept — now your position is too.) Note:
saves made *before* this release will still start over the first time.

### 🛰 Handy over WiFi — sync through quiet stretches
Scripts with a long no-action stretch — a slow intro, or a lull in the middle of a round — used to leave the
device lagging about 8 seconds behind once the action resumed. It now **engages fresh and in time** right as
the strokes come back, whether the quiet part is at the start of a round or in the middle.
