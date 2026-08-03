# Changelog

## v0.7.2

The big one for creators: **premium renditions** — sell a paid add-on that layers new content onto a free
base journey — plus the **journey packaging** that makes it possible, so a whole journey (or a free/paid
split of one) travels as a single file. The base game is never touched; players who own a rendition get the
richer version, everyone else plays the base. Paid renditions / base journeys are now locked by default when imported.
If you export your journey as split and mark as paid the journey will be locked for editing on import. Users will not be
able to edit the journey structure. If it is a free journey and or rendition they will retain the ability to edit those.

### 🧬 Renditions (premium add-ons)
A **rendition** is an overlay that adds content on top of an existing journey — extra fork paths, new
rounds, added scripts — **composed on at play time**. The base journey is never rewritten: it stays exactly
as shipped, and the rendition is layered over it in memory when someone who owns it plays. You author one
right in the builder **over the base itself** — the base nodes show ghosted, and you extend from them. This
is the foundation for selling structure and scripts while the base (and its video) stays free.

### 🍴 Overlay fork choices & open slots
A rendition can add a **brand-new choice to a fork that already exists in the base**, with the same options
as any base choice — its own name, image, gate condition, effects, or an ending that stops the run. The
fork's prompt stays owned by the base; the rendition just contributes another door. It can also **fill a
fork's reserved open slot** — a blank choice the base author left for a rendition to complete.

### 🎛 Multi-axis & vibe as a rendition
Sell the **multi-axis experience** on top of a single-axis base. Click a base round, drag your **T-code
axis (OSR2/SR6) and vibe scripts** into the side panel, and they route to the right channel by filename
suffix — no re-authoring the round. The base ships with the main stroke; owners get every axis and vibe
layered on. Picked the wrong file? Remove it and drop the right one.

### ✂ Extract & merge (authoring)
Two moves for carving a base into base-plus-rendition. **Extract** pulls a branch out of the base into a
new rendition (the base loses it, you Save; undo removes the rendition again). **Merge** does the inverse —
right-click a rendition's boundary node and fold **that node and its whole branch** back into the base in
one move, edges intact. Both carry their media across automatically.

### 📦 Journey packaging (`.fhj`) & the free/paid split
Export a whole journey as a single **`.fhj` file** and import it on another install. Export **self-contained**,
or **split it** into a **free video pack** and a **paid scripts pack** — because scene video is always meant
to be given away, never sold, while your scripts and structure are the sellable part. Import recombines the
two packs slot-for-slot back into a playable journey, and a duplicate import lets you overwrite, skip, or
bring it in as a copy. It streams multi-GB video without choking, and packages what's on disk without
re-baking anything.

### 🔗 Sequels that remember (cross-rendition resume)
Ship a rendition as a **sequel** and a **completed** base run carries your progress into it — coins, score,
items, flags, and counters all come along. It's a single-use carryover, consumed when the sequel finishes,
so finishing Part 1 sets you up for Part 2 without starting from nothing.

### 🔀 Rendition chains
A rendition can build on **another rendition**, not just on a base — so add-ons can stack (Part 3 on Part 2
on Part 1). The chain composes in order at play time.

### 🔒 Paid imports are edit-locked
A journey or rendition installed from a **paid (scripts-only) pack** comes in **locked** — the buyer can
play it and build their own renditions on top, but can't open it in the builder or re-export it. It's a
courtesy lock that keeps a creator's work theirs by default (not copy protection — the buyer still owns the
files).

### 🗂 Quality of life
- A rendition shows its **own cover image and description** in Journey Select — swapping between the base
  and a rendition swaps the picture and blurb too (each falls back to the base's when the rendition leaves
  it blank).
- **Delete a rendition** from the catalogue (with a heads-up if other renditions depend on it).
- Rendition editing is held to the **same validation bar as a base journey**, so a broken overlay can't slip
  through Save.
- The composed rendition nodes now show in the journey-select preview, and the builder's status toast no
  longer covers the Save button.
