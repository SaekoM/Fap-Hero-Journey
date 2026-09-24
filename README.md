# Fap Hero Journey

A Godot 4.6 application for creating and playing structured, interactive fap-hero experiences with support for T-code serial devices and Buttplug/Intiface-compatible toys.

---

## Features

### Player
- **Journey selector** — browse your journey library with cover art, tags, difficulty, and a detail modal showing the full round list, shops, and forks
- **Tag filtering** — filter journeys by content tags (Straight, Gay, Trans, Futa, Furry, Real, Animated, 2D, 3D, PMV, HMV, Multi-Axis, Vibe, and more)
- **Video playback** — MP4/MKV/WebM via EIRTeam.FFmpeg; funscript-only fallback if a video fails to open
- **Funscript sync** — playback locked to the video clock; free-running timer when no video is present
- **Fork paths** — player-choice branching at any point in a journey, with nested fork support
- **Shops** — spend coins earned during rounds on modifiers (range scale, clamp, block, etc.)
- **Storyboard scenes** — dialogue/image cutscenes between rounds with optional device filler during idle
- **Score system** — stroke amplitude scoring per round, tallied on the end screen
- **Coin economy** — rounds award coins; shops let you spend them on inventory items
- **Inventory panel** — slide-in view of active effects with live countdown timers
- **Save & Resume** — one save slot per journey; created at author-marked Checkpoint rounds or by buying "The Safe Word" item. Single-use (consumed on resume) and reset when the journey is re-saved or completed
- **Device status banner** — surfaces connection problems mid-game (Intiface disconnected, no device, selected device unavailable with fallback, serial port closed)

### Device Support
- **Buttplug / Intiface Central** — linear (stroker) and vibrator devices; auto-connect option
- **Serial T-code** — SR6, OSR2, and compatible devices over serial (configurable port + baud)
- **Multi-axis T-code** — secondary axes L1, L2, R0, R1, R2 driven by per-axis funscripts
- **Ease-in / ease-out** — smooth ramp from neutral at round start and on pause/stop (linear devices only; vibrators respond immediately)
- **Position clamp** — hard min/max range applied to all output, adjustable in Options
- **Storyboard filler** — keeps the device active during cutscenes with a configurable alternating stroke
  
### Builder
- **Graph-based editor** — pan/zoom node graph for authoring the full round sequence, with a **Fit-to-view** button and a built-in **shortcuts reference**
- **Bulk import** — drop a batch of files (or a whole folder, scanned recursively) and the builder creates one round per video, pairing each with its matching funscript by file name
- **Auto-fill & auto-route** — set a video and the matching funscript + secondary axis/vib scripts (`name_L1.funscript`, `name.vib1.funscript`, …) are pulled in automatically
- **Copy / Cut / Paste / Duplicate** — move whole modules (including storyboards with all their images, or entire nested forks) between branches
- **Multi-select** — marquee-drag or Ctrl+click to select several nodes, then copy/cut/delete/reorder them as a group
- **Undo / Redo** — every structural change is reversible
- **Live validation badges** — nodes flag missing funscripts, underfilled forks, or moved files before you save
- **Fork / Shop / Storyboard nodes** — branching paths with per-path image/name/description, purchasable modifier screens, and dialogue cutscenes
- **Tags** — toggle content tags per journey; defined in `data/tags.json` (no recompile needed)
- **Difficulty** — Easy / Medium / Hard / Very Hard / Extreme / Impossible
- **Non-destructive save** — staged to a temp folder then atomically swapped in, so a cancel or failure never touches the existing journey; videos are copied (or transcoded — see [Transcoding](#transcoding)) with a live, cancel-safe progress modal
- **Edit existing journeys** — rename, reorder, change funscripts without re-importing videos

---

## Requirements

| Requirement | Notes |
|---|---|
| **Godot 4.6 (.NET)** | Required to open or build the project |
| **EIRTeam.FFmpeg** | Required for MP4/MKV/WebM playback. [Releases →](https://github.com/EIRTeam/EIRTeam.FFmpeg/releases) |
| **ffmpeg + ffprobe** | Used by the builder to transcode non-H.264 video. Bundled in `bin/` on Windows; on Linux, install system ffmpeg (or set a custom path / turn auto-transcode off) — see [Transcoding](#transcoding) |
| **Intiface Central** | Required for Buttplug device support. [Download →](https://intiface.com/central/) |

---

## Setup

### EIRTeam.FFmpeg
1. Download the Godot 4 release for your platform from the [EIRTeam.FFmpeg releases page](https://github.com/EIRTeam/EIRTeam.FFmpeg/releases)
2. Extract the `addons/` folder into the project root
3. Reopen the project in Godot — video playback will be enabled automatically

### ffmpeg (for the Journey Builder)
1. Download a static ffmpeg build for Windows from [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) or [BtbN](https://github.com/BtbN/FFmpeg-Builds/releases) (the "essentials" or "full" build)
2. Copy `ffmpeg.exe` and `ffprobe.exe` into the `bin/` folder in the project root
3. In exported builds, these are packed into the distribution and extracted to the user data folder on first use — testers do not need to install ffmpeg separately

---

## Transcoding

The runtime decoder (EIRTeam.FFmpeg) only plays **H.264**, so the builder converts incompatible video on save. All of this is in **Options → Transcoding**:

- **Auto-Transcode Videos** (on by default) — when on, the builder transcodes non-H.264 video, and re-encodes H.264 that's in a pixel format the decoder can't handle (10-bit, 4:2:2/4:4:4) to 8-bit 4:2:0. Turn it **off** to copy videos as-is — useful if you prepare your own H.264 files, and it removes the ffmpeg requirement entirely.
- **FFmpeg Folder** — point the app at a folder containing `ffmpeg` and `ffprobe` if the bundled binaries can't run. A **Test** button confirms they launch.
- When auto-transcode is on but ffmpeg can't run, the save **stops with a clear message** rather than producing an unplayable round.

Transcodes use `libx264 -preset fast -crf 22 -pix_fmt yuv420p` with AAC audio.

---

## Building & Exporting

1. Open the project in **Godot 4.6 (.NET)**
2. Install export templates: **Editor → Manage Export Templates → Download and Install** (select the **.NET** variant)
3. **Project → Export → Add… → Windows Desktop**
4. In the **Options** tab, set the application name and icon
5. Uncheck **Debug** for a release build
6. Click **Export Project**

Testers receive a single folder containing the `.exe`, `.pck`, and a `bin/` subfolder with ffmpeg. No additional runtime installs are needed.

### Linux (native)

A native Linux build can be exported **from the same Windows editor** (cross-export works for .NET):

1. **Project → Export → Add… → Linux**
2. Set the application name; uncheck **Debug** for a release build
3. **Export Project** — produces the executable, `.pck`, and the EIRTeam.FFmpeg `.so` libraries (already bundled in `addons/ffmpeg/linux64/`)

Notes for Linux users:

- **Video playback** works out of the box (the FFmpeg decoder ships per-platform).
- **Transcoding (builder)** uses the system `ffmpeg`/`ffprobe` — the Linux build does **not** bundle them. Install via your package manager (`sudo apt install ffmpeg`, `sudo dnf install ffmpeg`, …), or set a custom path in **Options → Transcoding**, or turn **Auto-Transcode off** and supply your own H.264 videos. If auto-transcode is on and ffmpeg is missing, the builder explains it at save rather than producing an unplayable round.
- **Serial T-code devices** require your user to be in the `dialout` group to access `/dev/ttyUSB*` / `/dev/ttyACM*`: `sudo usermod -aG dialout $USER`, then log out and back in. (Buttplug/Intiface devices need no special permissions.)
- **Intiface Central** is available for Linux and connects exactly as on Windows.

---

## Journey File Format

Journeys are stored as folders inside the journeys directory (default `user://journeys/`, configurable in **Options → Storage Location**; open it via **Options → Open Journeys Folder**).

Playback assets (video, funscript, secondary-axis and vibrator scripts, boss images) are **pooled**: each file is stored once under `content/` with a content-based name (`m_<fingerprint>.<ext>`) and referenced from `journey.json` by an explicit relative path. An asset reused across rounds — e.g. one clip used by a Normal round on the main path *and* a Cursed round in a fork — is therefore stored **once** on disk and in the shared zip. The `media/` folder holds journey **images** (cover, storyboard, fork-path art).

Rounds don't have their own folders. Each round references its assets by explicit `VideoPath` / `FunscriptPath` / `AxisScripts` / `VibScripts` / `BossImage` paths (all into `content/`). The human-readable name lives in `journey.json`; `FolderName` (`r001`, `r002`, …) is still written as a stable per-round id — and the fallback used to load older journeys — but no per-round folder is created.

```
<journeys>/
└── My Journey/                          ← folder = sanitized journey name
	├── journey.json                     ← metadata, round list, forks, shops, storyboards
	├── media/                           ← journey images: cover, storyboard, fork-path art
	│   └── cover.png
	└── content/                         ← playback assets, pooled & deduped by content fingerprint
	    ├── m_4f1a2b3c8d9e0f12.mp4              ← video (copied, or transcoded to H.264)
	    ├── m_91c0a7e2d3b4f5a6.funscript        ← main stroke script
	    ├── m_2d7be4a1c0938f5d.pitch.funscript  ← optional secondary axis (.surge/.sway/.twist/.roll/.pitch)
	    ├── m_5e8c1a09f4b3d672.vibe1.funscript  ← optional vibrator channel (.vibe1/.vibe2)
	    └── m_6a3f0b9e8c1d2740.png              ← optional boss intro image
```

`journey.json` schema (abbreviated — keys are PascalCase):
```json
{
  "Name": "My Journey",
  "Author": "Author Name",
  "Description": "...",
  "Difficulty": "Medium",
  "Tags": ["straight", "real"],
  "Rounds": [
    { "Name": "Round 1", "FolderName": "r001", "Order": 1,
      "CoinsAwarded": 10, "RoundType": "Normal", "IsCheckpoint": false,
      "VideoPath": "content/m_4f1a2b3c8d9e0f12.mp4",
      "FunscriptPath": "content/m_91c0a7e2d3b4f5a6.funscript",
      "AxisScripts": {}, "VibScripts": {} }
  ],
  "Forks": [...],
  "Shops": [...],
  "Storyboards": [...]
}
```

> Older journeys saved before pooling used a per-round folder layout (`r001/video.mp4`, `r001/script.funscript`, …); they still load — the player falls back to those folder paths when the explicit `content/` paths are absent.

> The cover image isn't stored as a JSON key — it's auto-detected from `media/cover.*` when the catalogue scans the folder.

---

## Tags

Tags are defined in `data/tags.json`. Add, remove, or recolour tags without recompiling:

```json
[
  { "id": "straight", "label": "Straight", "color": "#4f8fff" },
  { "id": "real",     "label": "Real",     "color": "#e8c46a" }
]
```

Each entry requires `id` (lowercase, URL-safe), `label` (display text), and `color` (hex).

---

## Multi-Axis T-code

Secondary axes (L1, L2, R0, R1, R2) and vibrator channels (vib1, vib2) are supported for serial T-code devices. To use them:

1. **Easiest:** name the files with the axis/channel suffix (`scene.pitch.funscript`, `scene.vib1.funscript`, …) and drop them alongside the main video/funscript — the builder routes each to the right slot automatically (on bulk import, single-round drops, or via auto-fill)
2. **Manual:** expand the Extra Axes / Vibrator Scripts sections under a round and drop a `.funscript` onto each slot directly
3. On single-axis devices, secondary axis commands are silently ignored per the T-code spec

All axes ease in together from neutral at round start and ease out together on pause or stop.

---

## Keybinds

### During a Round

| Key | Action |
|---|---|
| `Space` | Pause / Resume |
| `Tab` | Toggle inventory panel |
| `Escape` | Close inventory (if open), otherwise return to main menu |

> These are suppressed while a full-screen overlay (shop, fork, storyboard) is active — the overlay handles input first.

### Journey Builder

| Key | Action |
|---|---|
| `Ctrl + S` | Save journey |
| `Ctrl + 1` / `2` / `3` / `4` | Add a round / shop / storyboard / fork |
| `Ctrl + C` / `Ctrl + X` / `Ctrl + V` | Copy / Cut / Paste selected module(s) |
| `Ctrl + Z` / `Ctrl + Y` | Undo / Redo (`Ctrl + Shift + Z` also redoes) |
| `Backspace` / `Delete` | Delete selected module(s) |
| `Left Click` (node) | Select node and open its editor |
| `Left Click` (fork branch) | Select the branch — add/paste to the top of that path |
| `Shift + Click` (node) | Select a range of nodes in the same branch |
| `Ctrl + Click` (node) | Add / remove a node from the selection |
| `Ctrl + A` | Select all nodes in the current branch |
| `Escape` | Clear selection |
| `Drag` (empty canvas) | Marquee-select nodes in one branch |
| `Middle Mouse + Drag` | Pan the graph canvas |
| `Scroll Wheel` | Zoom the graph canvas in / out |

> Editing shortcuts (copy/cut/paste/undo/redo/delete) defer to normal text editing while a text field is focused. A full reference is also available via the **⌨ Shortcuts** button in the builder. 

---

## Settings

Settings are stored in `user://settings.cfg` and managed through the in-app Options screen. No manual editing is required.

| Setting | Description |
|---|---|
| Master / Music Volume | Audio levels |
| Fullscreen | Exclusive fullscreen toggle |
| Resolution | Window size when not fullscreen |
| UI Scale | Scales the whole interface — raise it on high-resolution / 4K displays |
| HUD Auto-Hide | Delay before the in-game HUD fades |
| Beat Bar | Show upcoming stroke beats during play |
| Output Mode | Buttplug (Intiface) or Serial T-code |
| Intiface Address | WebSocket address for Intiface Central (default: `ws://localhost:12345`) |
| Serial Port / Baud | COM port and baud rate for T-code serial devices |
| Position Clamp | Hard min/max range applied to all device output |
| Storyboard Filler | Keep device active during cutscenes; configurable speed and range |
| Storage Location | Folder where journeys are stored; existing journeys move automatically |
| Auto-Transcode / FFmpeg Folder | Video transcoding controls (see [Transcoding](#transcoding)) |

---

## Project Structure

```
Globals/            Autoloaded services (GDScript + C#)
  ButtplugService.cs
  FunscriptPlayer.cs
  GameState.cs
  SettingsService.gd
  TagRegistry.gd
  UITheme.gd
  ...

scripts/            Scene-specific scripts
  game_loop/
  journey_builder/
  journey_select/
  options/
  ...

scenes/             .tscn scene files
data/               Runtime data files
  tags.json
bin/                ffmpeg / ffprobe binaries (not committed)
```

---

## License

Copyright (c) 2025 SaekoMStudio. All rights reserved.

This software is provided for personal, non-commercial use only.
Redistribution, resale, or modification without explicit written permission is prohibited.

### Third-party software

This application uses the following open-source components:

- **Godot Engine** — MIT License — https://godotengine.org
- **EIRTeam.FFmpeg** — MIT License — https://github.com/EIRTeam/EIRTeam.FFmpeg
- **FFmpeg** — LGPL 2.1 — https://ffmpeg.org
- **Buttplug.io** — BSD 2-Clause — https://buttplug.io
