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

### Device Support
- **Buttplug / Intiface Central** — linear (stroker) and vibrator devices; auto-connect option
- **Serial T-code** — SR6, OSR2, and compatible devices over serial (configurable port + baud)
- **Multi-axis T-code** — secondary axes L1, L2, R0, R1, R2 driven by per-axis funscripts
- **Ease-in / ease-out** — smooth ramp from neutral at round start and on pause/stop (linear devices only; vibrators respond immediately)
- **Position clamp** — hard min/max range applied to all output, adjustable in Options
- **Storyboard filler** — keeps the device active during cutscenes with a configurable alternating stroke

### Journey Builder
- **Graph-based editor** — pan/zoom node graph for authoring the full round sequence
- **Round nodes** — drag-and-drop funscript and video assignment; multi-file drop imports all axis scripts at once
- **Multi-axis scripts** — per-axis drop zones (L1, L2, R0, R1, R2) under each round node
- **Fork nodes** — branching paths with per-path cover image, name, and description
- **Shop nodes** — insert purchasable modifier screens between rounds
- **Storyboard nodes** — dialogue scenes with speaker, text, and optional images
- **Tags** — toggle content tags per journey; defined in `data/tags.json` (no recompile needed)
- **Difficulty** — Easy / Medium / Hard / Very Hard / Extreme / Insane
- **Non-destructive save** — videos are copied (or transcoded to H.264 via bundled ffmpeg if needed) with a live progress modal; cancel-safe
- **Edit existing journeys** — rename, reorder, change funscripts without re-importing videos

---

## Requirements

| Requirement | Notes |
|---|---|
| **Godot 4.6 (.NET)** | Required to open or build the project |
| **EIRTeam.FFmpeg** | Required for MP4/MKV/WebM playback. [Releases →](https://github.com/EIRTeam/EIRTeam.FFmpeg/releases) |
| **ffmpeg + ffprobe** | Required for video transcoding in the builder. Place in `bin/` (see below) |
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

## Building & Exporting

1. Open the project in **Godot 4.6 (.NET)**
2. Install export templates: **Editor → Manage Export Templates → Download and Install** (select the **.NET** variant)
3. **Project → Export → Add… → Windows Desktop**
4. In the **Options** tab, set the application name and icon
5. Uncheck **Debug** for a release build
6. Click **Export Project**

Testers receive a single folder containing the `.exe`, `.pck`, and a `bin/` subfolder with ffmpeg. No additional runtime installs are needed.

---

## Journey File Format

Journeys are stored as folders inside `user://journeys/` (accessible via **Options → Open Journeys Folder**).

```
user://journeys/
└── My Journey/
	├── journey.json          ← metadata, round list, tags, difficulty
	├── media/                ← cover image and storyboard images
	├── Round 1/
	│   ├── Round 1.funscript
	│   ├── Round 1_L1.funscript   ← optional secondary axis
	│   └── video.mp4
	└── Round 2/
		└── ...
```

`journey.json` schema (abbreviated):
```json
{
  "Title": "My Journey",
  "Author": "Author Name",
  "Description": "...",
  "Difficulty": "Medium",
  "Tags": ["straight", "real"],
  "CoverPath": "media/cover.jpg",
  "Rounds": [...],
  "Forks": [...],
  "Shops": [...],
  "Storyboards": [...]
}
```

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

Secondary axes (L1, L2, R0, R1, R2) are supported for serial T-code devices. To use them:

1. In the Journey Builder, expand the **Extra Axes (Serial Only)** section under a round node
2. Drop the corresponding `.funscript` file onto each axis drop zone
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
| `Middle Mouse + Drag` | Pan the graph canvas |
| `Scroll Wheel` | Zoom the graph canvas in / out |
| `Left Click` (node) | Select node and open its editor in the side panel |
| `Left Click` (empty canvas) | Deselect |

---

## Settings

Settings are stored in `user://settings.cfg` and managed through the in-app Options screen. No manual editing is required.

| Setting | Description |
|---|---|
| Master Volume | Overall audio level |
| Fullscreen | Exclusive fullscreen toggle |
| Resolution | Window size when not fullscreen |
| Output Mode | Buttplug (Intiface) or Serial T-code |
| Intiface Address | WebSocket address for Intiface Central (default: `ws://localhost:12345`) |
| Serial Port / Baud | COM port and baud rate for T-code serial devices |
| Position Clamp | Hard min/max range applied to all device output |
| Storyboard Filler | Keep device active during cutscenes; configurable speed and range |

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
