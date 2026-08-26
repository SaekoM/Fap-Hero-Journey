# Changelog

## v0.8.2

The crackling is gone — properly this time, in the video decoder itself rather than around it. Alongside
it: boss health thresholds that can finally say what they mean, regions that stop handing out damage for
video nobody watched, and a few rough edges from the first encounters built in anger.

### ◆ Crackling audio — the actual cause

v0.8.0 fixed *a* crackle: the project mixed at 44.1 kHz while video audio is 48 kHz, so every clip was
resampled continuously. That was real, and it is still fixed. It was not the whole story — players on
48 kHz sources kept reporting the same noise, sporadically, on journeys whose source files were clean.

The survivor was in **EIRTeam.FFmpeg**, the video decoder. It handed decoded audio to the engine only
once a chunk was already due, so the mixer was never more than a frame or so ahead. Any hitch longer
than a frame — a garbage collection, a texture upload, a busy scene — and the buffer ran dry. The engine
fades a starved block to silence and jumps back to full amplitude on the next one, and that discontinuity
is the crackle. It landed on the mix-block grid, which is why it was audible as a tick rather than a
dropout, and why it came and went between sessions: whether the buffer ran close to empty was decided by
each session's timing.

Audio is now handed over up to 100 ms ahead, so a hitch eats headroom instead of the mixer's next block.
Playback timing is unchanged — the buffer drains in real time either way.

This required patching the decoder and building it, so the addon is now a **custom build** rather than
the stock release. The fix has been offered upstream, where this has been an open report for years.

### ◆ Regions that mean what they say

**A boss-health condition is authored as a percentage.** Boss health is the one signal the model keeps as
a 0–1 fraction, and the shared rule editor offered a whole-number box for it — so a fraction could only
ever be 0 or 1, and "at or below 10%" was stored as "at or below 1000%". That is true at every health
there is, so the region played every time. It now reads and writes percent, matching the phase
thresholds beside it.

**Existing rules are migrated without changing what they do**, which is worth understanding before
re-testing an encounter: a rule that was already always-true stays always-true, displayed as 100%. The
fix makes the threshold *expressible*, not retroactively correct — **a health threshold authored before
this release has to be entered again** to mean what its author intended.

**Skipped video no longer pays out.** A region skip moved the playhead but left the funscript's cursor
behind, so the next frame fired every stroke the jump had passed over and scored all of them at once. A
thirty-second skip landed thirty seconds of strokes in a single frame — as damage, in a boss round, which
is why a fight could lose most of a health bar to a scene nobody watched. The same flaw applied to the
win skip-ahead, where it had gone unnoticed.

**A skip fades rather than cuts.** The picture fades down, moves while dark, and comes back when the next
clip is actually ready. A skip that ends the round stays dark and hands the screen to the round
transition, so the frames a region exists to hide are never briefly revealed on the way out.

### 🩹 Fixes

- **The boss telegraph no longer replays between attempts.** Its intro card announced the fight again on
  every pass, including a resume onto a fight already in progress. It plays on arrival now, which is the
  only time there is anything to announce.
- **Leaving the builder asks first.** BACK returned to the catalogue immediately, and any unsaved work
  went with it. It now offers to save, discard, or stay — and only when there is genuinely something
  unsaved, so a journey opened and closed unchanged still leaves without comment.

## v0.8.1

A fast follower for v0.8.0, from the first real encounters built with it: conditional video regions, a
colour of the boss's own, and the phase editor moved somewhere it makes sense.

### ◆ Regions — video that only plays when it should

A new **REGION** lane marks a stretch of the round's clip that **plays only when its rule holds**. When
the rule fails, the round jumps straight over it.

That makes a scene conditional. No climax until the boss is beaten. No foreplay after the first attempt.
The two examples are literally *boss health = 0* and *attempt = 1* — regions read the same player state
every other rule in an encounter does: score, pace, items used, boss health, attempt number.

Regions sit at the top of the lanes, because they decide whether the rest of them get to happen.

Three things worth knowing before you author one:

- **The rule is asked once, when the playhead arrives**, and then held. A region that starts playing
  finishes. Re-testing mid-scene could yank the video away the moment regeneration nudged the boss's
  health back over a threshold, and a clip that stops halfway for no visible reason is worse than either
  answer.
- **Skipping a region skips its funscript too**, so the score it would have earned is not earned. Regions
  are a balance lever, not only a presentation one — "no foreplay after attempt 1" also means less damage
  available on attempt 2.
- **Forward only.** A region is skipped past, never looped back to.

Gating the last scene on a win pairs with the existing **skip ahead on win**: win, jump to the ending, and
the ending plays *because* you won.

### ◆ A boss of your own colour

The health bar, its corner brackets, its glow and the boss's name now take a colour you pick per
encounter, instead of always being red.

A **phase can still override it** for its own stage, and **stances keep their fixed colours** — those are
a vocabulary a player learns once and reads on every boss, so an encounter does not get to redefine what
GUARDING looks like.

An encounter that never picks a colour still follows the theme rather than being pinned to whatever red
was current when it was made.

### ◆ Phases moved to the health bar

Phases were edited on a strip inside the **timeline**, which was the wrong place: a phase begins at a
**health** point, not a time, so the strip could not zoom or scroll with the lanes it sat above.

Worse, against a TIME-based bar health *is* inverted time — so the strip appeared to line up with the
clock, and silently stopped meaning that the moment an encounter switched to SCORE.

They now live with the health bar's other settings, as a list: threshold, name, colour, banner. The
preview's bar still shows the divisions, so the result is still visible where it matters.

Dragging went with the move, deliberately. A threshold is a number — "the boss changes at 60%" needs no
video to decide — unlike event timing, where dragging against the picture is how you find the frame.

### 🩹 Fixes

- **The boss is no longer assumed to be female.** Every label, tooltip and heading in the encounter editor
  now says **the player** and **the boss**. The two endings read IF THE PLAYER WINS and IF THE BOSS WINS.
- **A boss with attempts left no longer skips its replay** when a region or a win jump lands on the end of
  the clip. Ending a round that way ran the whole round-end *inside* the seek, and the rest of the jump
  then applied itself to the round that had just been loaded — burning every remaining attempt in a single
  frame, which looked exactly like advancing to the next node.
- **SPACE starts the preview instead of re-opening the encounter.** The builder's EDIT ENCOUNTER button
  kept keyboard focus behind the modal and was activating itself. The same bug applied to every button in
  the encounter's own inspector after the first edit — clicking ＋ SEGMENT and pressing SPACE added
  another segment rather than playing.

## v0.8.0

The **boss encounter** release. A boss round used to be a normal round with forced modifiers and an intro
card. It can now be an authored fight — attacks that seize the device, dialogue and art over the video, a
health bar that answers to how you play, and moves that vary between attempts.

Override items and a few smaller things ship alongside it.

### ◆ Boss encounters

A boss round can now carry an **encounter**: a set of authored moments placed on the round's own video
clock. Everything below is optional. A boss round with no encounter plays exactly as it did before, and so
does every journey made until now.

#### The parts of an encounter

An encounter is built from five kinds of thing, each on its own lane:

- **Attacks** — the boss takes the device. The boss's funscript plays instead of the round's for as long as the
  attack lasts, then hands it back. This is the move itself, not a picture of one.
- **Cast** — a character portrait or a piece of art appears over the video, with an optional line of
  dialogue underneath. Used for telegraphs, taunts, and the moments either side of a fight.
- **Audio** — a one-shot sound or a line of narration. Narration ducks the rest of the mix so it can be
  heard over the round.
- **Effects** — a window of time during which a modifier applies: the stroke scaled, clamped, reversed,
  blacked out, and so on. The same modifiers items use, held open for a stretch instead of a duration.
- **Stances** — a window during which the boss takes damage differently. Explained under the health bar
  below.

#### The health bar

Every encounter can show a named health bar. What drains it is the author's choice:

- **Time** — the round's own progress, shown backwards. Cosmetic, and what every boss did before.
- **Score** — it empties as you *earn*. This is what turns a boss round into a fight.

With a score bar the author sets a **score to defeat**, and emptying the bar wins. The builder tells them
exactly what a full pass of the round is worth, so the target is a decision rather than a guess.

**Phases** divide the bar into stages. A phase begins when the boss's health drops to a point the author chose —
"below 60%" — rather than at a time on the clock, so the divisions on the bar always mean what they show.
A phase can announce itself with a banner and recolour the bar.

#### Stances — when to push, and when not to

A stance window changes how much damage lands, and the bar says which one is in force:

| Stance | Effect |
| --- | --- |
| **NORMAL** | ordinary damage |
| **GUARDING** | half damage — the boss is covering up |
| **IMMUNE** | nothing lands at all |
| **VULNERABLE** | double damage — an opening |
| **RECOVERING** | the bar runs *backwards*; the boss is healing |
| **ATTACKING** | nothing lands, because the boss is the one doing something |

The bar takes the stance's colour, glows in it, and names it in a word underneath. This is the part that
makes a boss round something you play rather than sit through: hold back through a guard, go hard through
an opening, and read the bar for which is which.

**A boss's own attacks make it untouchable.** While an attack runs, the script driving the device is the
boss's — so
it deals no damage, and no override item can cut in. An author who writes the boss's moves into the
round's own funscript instead of using the attack lane can mark those stretches ATTACKING by hand and get
the same behaviour.

#### The fight — losing, and going again

A boss can be given more than one **attempt**. Run out of bar without winning and the round replays from
the start, **carrying the damage you already did**. The bar shows which attempt you are on.

Two endings can be authored, each a set of cast and audio cues that plays as the round bows out:

- **If the player wins** — the moment the boss goes down. The round then plays out as aftermath rather
  than cutting
  short, and can optionally skip ahead to a point the author marked on the timeline.
- **If the boss wins** — played when the attempts run out, and also when the player presses FINISH
  mid-round.
  Both are the same defeat.

Either ending can raise a **flag**, so a later fork can ask how the fight went — advancing past a boss no
longer means you beat it.

A boss can also **recover**: across an authored window, while the game is **paused**, or a share of the bar
returned **between attempts**.

#### Encounters that don't repeat themselves

Three tools, each for a different kind of repetition:

- **Alternatives** — a cue can carry other versions of itself, one picked each time the round starts. The
  original counts as a candidate, so two alternatives means three possible lines. An alternative can bring
  its own art, its own framing, and its own expression of the same character.
- **Segments** — a whole *move* varies together. A segment names two or more branches and exactly one
  plays. Tag the telegraph, the attack and the impact sound with the same branch and all three swap as a
  unit, which is what stops a fight assembling combinations nobody wrote. Two attacks on different
  branches may start at the same moment and run for completely different lengths.
- **Conditions** — a branch, or any single cue, can be gated on what the player has actually done: their
  score, their pace, how many items they have used and which, how much health the boss has left, and which
  attempt this is. Rules are read in the order they are written, and whatever carries no rule is what the
  dice choose between.

Conditions are checked at the moment the cue comes up, so "score above 500" means *by the time the cue got
there* — not a guess made when the round began.

#### Items during a boss

Boss rounds locked items out entirely. An encounter can now **allow them**, which makes an item a real
answer to a fight rather than something you carry past it. A boss round without an authored encounter
keeps the old lockout, so nothing already made changes.

While the boss is attacking, override items are refused rather than spent — the card says so and stays in
inventory.

### ◆ Override items

A new kind of item that **takes the device** when used, plays its own funscript over the round, and hands
control back. Authors give it a script bundle (main plus any axes and vibration channels), an optional
slice of that script, and optional effects that apply while it runs.

- Overrides can be **tested on the device** from the builder without playing a round.
- A **3D simulator** shows multi-axis scripts as they will move.
- An override may not interrupt a boss's attack — the encounter is the authored thing.

### ◆ Items that fight back

- A new **score effect** adds points the instant an item is used. In a boss round with a score health bar
  that *is* damage — and it runs through the boss's stance, so a thrown punch lands, glances off a guard, or is
  swallowed whole by an attack. Outside a boss round it is simply points.
- Items can carry their **own sound**, played instead of the standard click, at a volume you set. A
  gunshot on a bullet, a thud on a punch.
- Every audio field in the builder now has a **▶ TEST button** — item sounds, fork audio, storyboard music
  and line audio. Levels used to be something you set by eye and found out about in a round.

### ◆ Checkpoints save automatically

Reaching a checkpoint now **writes your resume point immediately**. Close the game whenever you like and
you come back to the last one you passed — no button to remember, and it re-arms every time you pass
another.

**Save & Quit** is still there for stopping deliberately. The reward some checkpoints granted for
*skipping* the save has been removed: there is no longer a break to skip.

### ✨ Interface

The encounter editor and the builder panels grew a lot this release. A pass over both:

- **Encounter settings fold.** HEALTH BAR, SEGMENTS and HOW THE ROUND CAN END are now collapsible
  sections rather than one forty-control scroll where a checkbox carried the same weight as a segment
  list. Open sections stay open while you type.
- **Branches sit inside the segment that owns them**, indented behind a rail, with the tag field sized
  for a tag rather than a sentence. Two segments used to read as four peers with nothing saying which
  belonged together — and a branch's warnings now sit on that branch instead of at the top of the list.
- **Amber means a problem again.** A brand-new encounter used to open with two amber warnings before
  anything had been authored, neither of them a mistake. Those are quiet notes now, and the FINISH
  warning only raises once there are cues it would actually strand.
- **Volume is a percentage everywhere**, and each volume sits on one line with a compact ▶ TEST beside
  it instead of a full-width button underneath.
- **Selected nodes are outlined in white** instead of a brighter version of their own colour — two amber
  storyboards side by side both looked selected.
- **Long node names end in an ellipsis** and show in full on hover, rather than being cut mid-word with
  no sign it had happened.
- **Item and character windows size to their contents** instead of always reserving room for ten rows.
- **The health bar's position reads as a percentage**, matching the phase thresholds beside it.
- Under the health bar, **NORMAL now shows nothing at all**. The absence is the signal — a dim word at
  that size read as a smudge on the video.

### 🩹 Fixes

- **Crackling audio in videos.** The project mixed at 44.1 kHz while video audio is almost always 48 kHz,
  so every clip was resampled continuously during playback — then resampled again by the sound device on
  the way out. The mix rate now matches the content and the resampling is gone.
- **Boss attacks no longer damage the boss.** The script playing during an attack is the boss's, so the score it
  dealt was being counted against the boss.
- **Audio ease in/out on encounter cues** is saved. The controls existed and the runtime honoured them;
  the value was discarded in between.
- In the cut editor the **OUT marker is red** — it used to share amber with the playhead.
- **→ in the Quick Settings drawer** nudges the stroke range again. It was bound twice and the second
  binding never ran.
- The boss round panel **no longer claims boss rounds disable item use** — an encounter decides that now,
  and the old text taught the opposite of how this release works.
- **DELETE JOURNEY** moved to the end of its row, behind a gap. It sat between EDIT and EXPORT: the one
  irreversible action among safe ones, the same size and weight as both.

### 🧰 For creators (builder)

- The encounter editor is a **video-editor-style modal**: lanes against the round's clock, a live preview
  running the real cue layer and health bar, drag to move, drag an edge to trim, CTRL+wheel to zoom.
- **Both edges of a media block cut into the source**, so an attack or an audio cue can be reduced to its
  middle instead of always starting at the first stroke.
- The preview can **play either ending on demand** and **pin any alternative**, so nothing has to be
  reached by losing a fight or re-rolling until it comes up.
- A **simulated player** panel drives the preview's conditions, so branching can be checked without
  playing the round.
- **Storyboards can be named.** The name labels the node on the map instead of the first speaker's name,
  which made every scene the same character opens look identical. Players never see it.

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
