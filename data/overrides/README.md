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

On save, a journey that can hand out a built-in override copies its funscript(s) into the journey's
`content/` so the files travel in an exported `.fhj` (the §5c reachable-set copy).
