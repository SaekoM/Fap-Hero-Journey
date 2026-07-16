# Changelog

## v0.6.1

A fix-first release. **v0.6.0's Windows build shipped without its bundled ffmpeg**, which broke
saving journeys — that's sorted. Along with it: a much faster way to build Pool Rounds, boss
encounters, reusable round templates, and a couple of long-standing bugs squashed.

### 🛠 The ffmpeg fix — read this if v0.6.0 wouldn't save
The v0.6.0 Windows download was missing the bundled **ffmpeg / ffprobe**, so saving a journey failed with *"ffmpeg / ffprobe could not be run"* unless you happened to already have ffmpeg installed system-wide. The binaries are back in the Windows build — just update, nothing else to do. Sorry for the run-around.

If you worked around it by switching **Auto-Transcode** off, you can safely turn it back on in Options → Transcoding.

*Linux:* the Linux build has never bundled ffmpeg and still uses your system one — install it from your package manager (`apt install ffmpeg`, or your distro's equivalent) if saving complains.

### ⚔ Pool Rounds — build them in seconds
- **Drop a folder in.** Building a pool used to mean adding encounters one at a time. There's now a **drop zone**: drop in a pile of videos — or whole folders — and every video becomes an encounter, with its funscript, extra-axis and vibrator scripts matched up by filename.
- **Encounters can be bosses.** Any encounter in a pool can be flagged a **boss**, with its own forced modifiers, intro tagline and image. Roll it and the mystery card gives way to the boss intro — open the door, and maybe it's a boss.
- **Extra axes & vibrator scripts** are now editable per encounter. They were always being loaded and played; you just had no way to see or change them.

### ★ Round templates
Save any round's full definition — media, round type, boss setup, its entire encounter pool — as a named **template**, then apply it to another round in two clicks. No more rebuilding the same pool by hand.

### 🎁 Round rewards
Rounds can now **award an item** when they finish, the same way storyboards already could. Pick one from the round's *Item Reward* dropdown and the player gets it — with a toast — as the round ends.

### 🔖 Journey version stamps
Journeys now record the version of FHJ that built them. Open one made for a newer version than you're running and you'll get a clear heads-up instead of a confusing failure.

### 🐛 Fixes
- **Fork screens always read "0 ROUNDS"** on every path. They now show how many rounds each branch actually holds.
- **Journey Audit ignored Pool Rounds.** They counted as zero score and zero length, quietly skewing score totals, run-length estimates and checkpoint spacing. Pool rounds are now measured from their encounters — including the best/worst range across whichever one gets rolled.