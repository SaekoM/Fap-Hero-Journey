# Changelog

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
