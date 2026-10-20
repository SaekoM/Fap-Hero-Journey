# Built-in override strokes

Funscripts backing the **built-in override items** (see `OVERRIDE_ITEMS_DESIGN.md`). Each override item
plays its bundled funscript over the round when activated, then hands control back.

## Layout

One folder per item, keyed by the item's `id`:

```
data/overrides/<item_id>/main.funscript      # required — the main stroke (L0)
data/overrides/<item_id>/R1.funscript        # optional axis (L1/L2/R0/R1/R2), one file each
data/overrides/<item_id>/vib1.funscript      # optional vibration (vib1/vib2)
```

## Registration

Each built-in override is an entry in `data/shop_items.json` with `category: "override"` and explicit
`scripts` paths (built-ins list them directly — the builder's filename auto-pairing is for authored items):

```jsonc
{
  "id": "the_grip",
  "name": "The Grip",
  "description": "A sudden, insistent squeeze.",
  "category": "override",
  "price": 45,
  "immune_to_effects": true,
  "scripts": { "main": "res://data/overrides/the_grip/main.funscript" }
}
```

Axis and vibration channels go in `scripts.axes` / `scripts.vibes` beside `main`, keyed by T-code axis
name and vibe channel:

```jsonc
"scripts": {
  "main": "res://data/overrides/clockwork/main.funscript",
  "axes": {
	"R0": "res://data/overrides/clockwork/main.twist.funscript",
	"R1": "res://data/overrides/clockwork/main.roll.funscript",
	"R2": "res://data/overrides/clockwork/main.pitch.funscript"
  }
}
```

On save, a journey that can hand out a built-in override copies its funscript(s) into the journey's
`content/` so the files travel in an exported `.fhj` (the §5c reachable-set copy).

## Authoring multi-axis channels (OFS)

- **Script against `main.funscript`** in the same folder and keep OFS's default suffixes: `main.twist`,
  `main.roll`, `main.pitch` (and `main.surge` / `main.sway` if wanted). Any file name works — the
  registration lists explicit paths — but the defaults keep every folder alike.
- **Twist = R0, roll = R1, pitch = R2, surge = L1, sway = L2.**
- **Same length as the stroke.** The override plays until its longest channel ends, so an axis running
  past the stroke stretches the takeover with the stroke standing still.
- **Start and end the axes at 50.** The device eases into an override from wherever it is, and hands the
  axes back to the round at the end; starting and ending at centre keeps both handovers clean.
- **Stay mostly inside 25–75 on the turning axes**, with occasional peaks further out. Every player's own
  axis windows still apply on top, and a full ±50 swing on every stroke feels violent (Vortex at 100%
  is the reference for "too much").
- **Keep the turning axes slower than the stroke.** A roll or pitch reversing on every fast stroke
  reads as shaking; half-time or slower usually feels intentional.
- **Write for players without the axes too.** Someone on a stroke-only device gets `main` alone, so the
  stroke has to be worth its price on its own.
