using Godot;
using Godot.Collections;
using System.Collections.Generic;

public partial class InventoryService : Node
{
    [Signal] public delegate void InventoryChangedEventHandler();
    [Signal] public delegate void ActiveEffectsChangedEventHandler();
    // Fired when a utility item with kind == "save_now" is activated.
    // GameLoop listens and writes a journey save in response. Separate signal
    // from ActiveEffectsChanged because save_now never enters _active.
    [Signal] public delegate void SaveRequestedEventHandler();
    // Fired when a utility item with kind == "skip_round" is activated. Same shape as
    // SaveRequested: instantaneous, never enters _active.
    [Signal] public delegate void SkipRoundRequestedEventHandler();
    // Fired when an override item (category == "override") is activated. GameLoop's takeover
    // coordinator loads the item's funscript bundle and plays it over the round. Like save_now/
    // skip_round it's instantaneous here (consumed, never enters _active).
    [Signal] public delegate void OverrideActivatedEventHandler(string itemId);

    // ---------------------------------------------------------------------------
    // Item registry
    // Loaded from res://data/shop_items.json on startup. Edit that file to tune
    // balance without touching C#. Falls back to hardcoded defaults if the file
    // is missing or malformed.
    // ---------------------------------------------------------------------------

    // Non-static so it is populated once the node is ready (autoload order is safe).
    private Dictionary _registry = new Dictionary();

    // Author-defined, JOURNEY-scoped items — loaded from the journey's Items block each run
    // (LoadJourneyItems) and merged into lookups alongside the built-in _registry. A journey item
    // carries an "effects" bundle (a list of tuned effect dicts) instead of a single kind. Cleared
    // and repopulated per journey load, so stale items from a prior journey never leak.
    private Dictionary _journeyItems = new Dictionary();

    // Path of the JSON data file inside the project.
    private const string RegistryPath = "res://data/shop_items.json";

    public override void _Ready()
    {
        _LoadRegistry();
    }

    private void _LoadRegistry()
    {
        _registry.Clear();

        if (FileAccess.FileExists(RegistryPath))
        {
            using var registryFile = FileAccess.Open(RegistryPath, FileAccess.ModeFlags.Read);
            if (registryFile != null)
            {
                var json = new Json();
                if (json.Parse(registryFile.GetAsText()) == Error.Ok && json.Data.VariantType == Variant.Type.Array)
                {
                    foreach (var item in json.Data.AsGodotArray())
                    {
                        if (item.VariantType != Variant.Type.Dictionary)
                            continue;
                        var d = item.AsGodotDictionary();
                        var id = d.ContainsKey("id") ? d["id"].AsString() : "";
                        if (id != "")
                            _registry[id] = d;
                    }

                    GD.Print($"InventoryService: loaded {_registry.Count} items from {RegistryPath}");
                    return;
                }

                GD.PrintErr($"InventoryService: failed to parse {RegistryPath} — using hardcoded defaults.");
            }
        }
        else
        {
            GD.PrintErr($"InventoryService: {RegistryPath} not found — using hardcoded defaults.");
        }

        _LoadHardcodedDefaults();
    }

    private void _LoadHardcodedDefaults()
    {
        _registry["long_game"] = new Dictionary
        {
            ["id"] = "long_game",
            ["name"] = "The Long Game",
            ["description"] = "Expands the funscript stroke length by 20%.",
            ["category"] = "modifier",
            ["price"] = 30,
            ["duration_ms"] = 30000,
            ["kind"] = "scale",
            ["factor"] = 1.2f,
        };
        _registry["cock_lock"] = new Dictionary
        {
            ["id"] = "cock_lock",
            ["name"] = "Cock Lock",
            ["description"] = "Ignores funscript playback for 10 seconds.",
            ["category"] = "modifier",
            ["price"] = 25,
            ["duration_ms"] = 10000,
            ["kind"] = "block",
        };
        _registry["shrink_ray"] = new Dictionary
        {
            ["id"] = "shrink_ray",
            ["name"] = "Shrink Ray",
            ["description"] = "Reduces the funscript stroke length by 20%.",
            ["category"] = "modifier",
            ["price"] = 40,
            ["duration_ms"] = 30000,
            ["kind"] = "scale",
            ["factor"] = 0.8f,
        };
        _registry["final_inch"] = new Dictionary
        {
            ["id"] = "final_inch",
            ["name"] = "The Final Inch",
            ["description"] = "Confines the script to only the top 50% of the stroke range.",
            ["category"] = "modifier",
            ["price"] = 35,
            ["duration_ms"] = 25000,
            ["kind"] = "clamp",
            ["min"] = 50,
            ["max"] = 100,
        };
        _registry["low_tide"] = new Dictionary
        {
            ["id"] = "low_tide",
            ["name"] = "Low Tide",
            ["description"] = "Confines the script to only the bottom 50% of the stroke range.",
            ["category"] = "modifier",
            ["price"] = 35,
            ["duration_ms"] = 25000,
            ["kind"] = "clamp",
            ["min"] = 0,
            ["max"] = 50,
        };
        _registry["mirror"] = new Dictionary
        {
            ["id"] = "mirror",
            ["name"] = "Mirror",
            ["description"] = "Inverts all stroke positions for 30 seconds. Up becomes down.",
            ["category"] = "modifier",
            ["price"] = 30,
            ["duration_ms"] = 30000,
            ["kind"] = "reverse",
        };
        _registry["blackout"] = new Dictionary
        {
            ["id"] = "blackout",
            ["name"] = "Blackout",
            ["description"] = "Hides the video for 30 seconds. The device keeps going in the dark.",
            ["category"] = "modifier",
            ["price"] = 20,
            ["duration_ms"] = 30000,
            ["kind"] = "blackout",
        };
        _registry["score_rush"] = new Dictionary
        {
            ["id"] = "score_rush",
            ["name"] = "Score Rush",
            ["description"] = "Doubles score earned from every stroke for 30 seconds.",
            ["category"] = "modifier",
            ["price"] = 40,
            ["duration_ms"] = 30000,
            ["kind"] = "score_multiplier",
            ["factor"] = 2.0f,
        };
        _registry["jackpot"] = new Dictionary
        {
            ["id"] = "jackpot",
            ["name"] = "Jackpot",
            ["description"] = "Doubles the coin reward at the end of this round.",
            ["category"] = "modifier",
            ["price"] = 50,
            ["duration_ms"] = 300000,
            ["kind"] = "coin_jackpot",
            ["factor"] = 2.0f,
        };
        _registry["pleasure_band"] = new Dictionary
        {
            ["id"] = "pleasure_band",
            ["name"] = "Pleasure Band Clamp",
            ["description"] = "Confines the script to the middle 30-70% of the stroke range.",
            ["category"] = "modifier",
            ["price"] = 35,
            ["duration_ms"] = 25000,
            ["kind"] = "clamp",
            ["min"] = 30,
            ["max"] = 70,
        };
        _registry["wildcard"] = new Dictionary
        {
            ["id"] = "wildcard",
            ["name"] = "Wildcard",
            ["description"] = "Activates a random modifier - could be anything. A cheap gamble.",
            ["category"] = "modifier",
            ["price"] = 20,
            ["duration_ms"] = 30000,
            ["kind"] = "wildcard",
        };
        // Utility item — saves progress at the start of the current round and
        // is consumed. Locked out during boss rounds (because the inventory
        // button itself is disabled during bosses). Doesn't apply a runtime
        // effect; GameLoop catches the SaveRequested signal and writes the
        // save file via JourneySaveService.
        _registry["safe_word"] = new Dictionary
        {
            ["id"] = "safe_word",
            ["name"] = "The Safe Word",
            ["description"] = "Saves your run at the start of the current round. One-time save — used up when you resume.",
            ["category"] = "utility",
            ["price"] = 120,
            ["duration_ms"] = 0,
            ["kind"] = "save_now",
        };
        // Key — held until spent at an item-conditional fork; not manually
        // activatable (see ActivateItem). Mirrors data/shop_items.json.
        _registry["key"] = new Dictionary
        {
            ["id"] = "key",
            ["name"] = "Key",
            ["description"] = "Opens a locked fork path. Consumed when the path is taken.",
            ["category"] = "utility",
            ["price"] = 50,
            ["duration_ms"] = 0,
            ["kind"] = "key",
        };
        // Bail Out — ends the current round for nothing. Manually activated, consumed on use.
        // Mirrors data/shop_items.json.
        _registry["skip_round"] = new Dictionary
        {
            ["id"] = "skip_round",
            ["name"] = "Bail Out",
            ["description"] = "Ends the current round immediately. It counts as played, but pays no coins, score or reward. Consumed when used.",
            ["category"] = "utility",
            ["price"] = 70,
            ["duration_ms"] = 0,
            ["kind"] = "skip_round",
        };
        // Cleanse — held until used on a cursed round; not manually activatable
        // (see ActivateItem). Mirrors data/shop_items.json.
        _registry["cleanse"] = new Dictionary
        {
            ["id"] = "cleanse",
            ["name"] = "Cleanse",
            ["description"] = "Lifts the curse on a cursed round for free. Consumed when used.",
            ["category"] = "utility",
            ["price"] = 60,
            ["duration_ms"] = 0,
            ["kind"] = "cleanse",
        };
    }

    // --- Registry access -------------------------------------------------------

    // Returns all registered item IDs in insertion order.
    public Array GetAllItemIds()
    {
        var ids = new Array();

        foreach (var key in _registry.Keys)
            ids.Add(key);
        foreach (var key in _journeyItems.Keys)
            ids.Add(key);

        return ids;
    }

    // Built-in registry ids only (no journey-scoped items). The BUILDER uses this: it merges these
    // with its OWN live journey-item model, so it must not also pull in _journeyItems (play-state left
    // over from a test-play — which would double-count this journey's items and leak another journey's).
    public Array GetBuiltinItemIds()
    {
        var ids = new Array();
        foreach (var key in _registry.Keys)
            ids.Add(key);
        return ids;
    }

    // Replaces the journey-scoped item set from the journey's Items block ([{id, name, description,
    // category, price, duration_ms, effects:[…]}, …]). Called on every journey load (fresh or
    // resumed), so it fully clears the previous journey's items first.
    public void LoadJourneyItems(Array items)
    {
        _journeyItems.Clear();
        foreach (var itemVar in items)
        {
            var item = itemVar.AsGodotDictionary();
            var id = item.ContainsKey("id") ? item["id"].AsString() : "";
            if (id != "")
                _journeyItems[id] = item;
        }
    }

    // Returns the data dictionary for the given item ID, or an empty dict if unknown.
    public Dictionary GetItemData(string id)
    {
        if (id != null && _registry.ContainsKey(id))
            return _registry[id].AsGodotDictionary();
        if (id != null && _journeyItems.ContainsKey(id))
            return _journeyItems[id].AsGodotDictionary();
        return new Dictionary();
    }

    // ---------------------------------------------------------------------------
    // Inventory (owned, not-yet-activated items)
    // ---------------------------------------------------------------------------

    private readonly List<Dictionary> _items = new();

    // Active effects: one entry per activation, with absolute end time on engine clock (ms).
    private readonly List<Dictionary> _active = new();

    // Boss-round forced effects. These never expire on the timer — they are added
    // when a boss round begins and removed wholesale via ClearBossEffects() when it
    // ends. GetActiveEffects() returns them alongside _active so every consumer
    // (FunscriptPlayer, ScoreService, the HUD chips) sees them transparently.
    private readonly List<Dictionary> _bossEffects = new();

    private double _nowMs = 0.0;

    // When true, the effect clock is frozen — _nowMs stops advancing so active
    // effects neither expire nor visibly count down. Driven by GameLoop while the
    // round is paused (pause button / Options overlay) so timed effects are not
    // drained while no round is playing.
    private bool _paused = false;

    // Freeze or resume the active-effect countdown. Idempotent.
    public void SetPaused(bool paused) => _paused = paused;

    public override void _Process(double delta)
    {
        if (_paused)
            return;

        _nowMs += delta * 1000.0;

        bool removed = false;
        for (int i = _active.Count - 1; i >= 0; i--)
        {
            if (_active[i]["end_time_ms"].AsDouble() <= _nowMs)
            {
                _active.RemoveAt(i);
                removed = true;
            }
        }

        if (removed)
            EmitSignal(SignalName.ActiveEffectsChanged);
    }

    public void Reset()
    {
        _items.Clear();
        _active.Clear();
        _bossEffects.Clear();
        // Clear any stale pause state — a player can quit to menu mid-pause,
        // which would otherwise leave the effect clock frozen for the next journey.
        _paused = false;
        EmitSignal(SignalName.InventoryChanged);
        EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // --- Inventory ----------------------------------------------------------

    public Array GetItems()
    {
        var arr = new Array();
        foreach (var item in _items)
            arr.Add(item);

        return arr;
    }

    public void AddItem(string id)
    {
        var data = GetItemData(id);
        if (data.Count == 0)
            return;

        _items.Add(data);
        EmitSignal(SignalName.InventoryChanged);
    }

    // True if the player currently holds at least one item with this id. Used by
    // Sacrifice forks (gating) and item-Conditional forks (the ownership check).
    public bool OwnsItem(string id)
    {
        foreach (var item in _items)
            if (item.ContainsKey("id") && item["id"].AsString() == id)
                return true;
        return false;
    }

    // Removes one held item with this id. Returns true if one was removed. Used
    // when a Sacrifice fork path is chosen.
    public bool ConsumeItem(string id)
    {
        for (int i = 0; i < _items.Count; i++)
        {
            if (_items[i].ContainsKey("id") && _items[i]["id"].AsString() == id)
            {
                _items.RemoveAt(i);
                EmitSignal(SignalName.InventoryChanged);
                return true;
            }
        }
        return false;
    }

    // ─── Save / Resume ────────────────────────────────────────────────────
    //
    // Inventory portion of the journey save record. Only owned (unactivated)
    // items are persisted — active effects are deliberately NOT carried
    // across saves so the player gets a clean modifier slate on resume.

    // Captures the current owned-inventory list for inclusion in the save
    // payload. Same shape GetItems() exposes; we keep a dedicated method so
    // the save callsite is explicit about intent.
    public Array CaptureSaveData() => GetItems();

    // Restores an inventory list from a save record. Each entry is looked up
    // fresh in _registry by ID so registry edits made since the save (item
    // removed, price changed, description rewritten) take effect on resume.
    // Saved IDs that no longer exist in the registry are silently dropped.
    public void LoadFromSave(Array savedItems)
    {
        _items.Clear();
        foreach (var entry in savedItems)
        {
            if (entry.VariantType != Variant.Type.Dictionary)
                continue;
            var saved = entry.AsGodotDictionary();
            string id = saved.ContainsKey("id") ? saved["id"].AsString() : "";
            if (id == "")
                continue;
            if (_registry.ContainsKey(id))
                _items.Add(_registry[id].AsGodotDictionary());
            // else: item id no longer in registry — silently drop. Common
            // after a content update that removes or renames an item.
        }
        EmitSignal(SignalName.InventoryChanged);
    }

    // Removes the item at slotIndex and starts its effect timer immediately.
    public bool ActivateItem(int slotIndex)
    {
        if (slotIndex < 0 || slotIndex >= _items.Count)
            return false;

        var item = _items[slotIndex];

        // Keys and Cleanses aren't manually usable — a Key is consumed at an
        // item-conditional fork, a Cleanse via the cursed-round cleanse button.
        // Refuse activation so the player can't waste one.
        string itemKind = item.ContainsKey("kind") ? item["kind"].AsString() : "";
        if (itemKind == "key" || itemKind == "cleanse")
            return false;

        _items.RemoveAt(slotIndex);

        // save_now is an instantaneous utility — it doesn't enter the active-
        // effect list, it just fires a signal for GameLoop to handle and is
        // consumed. Boss-round lockout is enforced by the inventory UI (which
        // disables item use during bosses) so the activation-side code doesn't
        // need its own boss check.
        if (item.ContainsKey("kind") && item["kind"].AsString() == "save_now")
        {
            EmitSignal(SignalName.SaveRequested);
            EmitSignal(SignalName.InventoryChanged);
            return true;
        }

        // skip_round is the same instantaneous shape: GameLoop ends the round with no payout.
        if (itemKind == "skip_round")
        {
            EmitSignal(SignalName.SkipRoundRequested);
            EmitSignal(SignalName.InventoryChanged);
            return true;
        }

        // Override items hand off to GameLoop's takeover coordinator (it loads the bundled funscript and
        // plays it over the round). A PLAIN override is done here; one that ALSO bundles effects falls
        // through to apply them (for the override's duration) alongside the device takeover.
        if ((item.ContainsKey("category") ? item["category"].AsString() : "") == "override")
        {
            EmitSignal(SignalName.OverrideActivated, item.ContainsKey("id") ? item["id"].AsString() : "");
            if (!item.ContainsKey("effects") || item["effects"].AsGodotArray().Count == 0)
            {
                EmitSignal(SignalName.InventoryChanged);
                return true;
            }
        }

        // Wildcard resolves to a random concrete modifier at activation time: the
        // rolled effect supplies the kind + params, the displayed name reveals
        // what was rolled. Every other item is its own effect source.
        var source = item;
        string displayName = item.ContainsKey("name") ? item["name"].AsString() : "";
        if (item.ContainsKey("kind") && item["kind"].AsString() == "wildcard")
        {
            var rolled = _RollWildcard();
            if (rolled.Count > 0)
            {
                source = rolled;
                string rolledName = rolled.ContainsKey("name") ? rolled["name"].AsString() : "";
                if (rolledName != "")
                    displayName = $"Wildcard: {rolledName}";
            }
        }

        int duration = item.ContainsKey("duration_ms") ? item["duration_ms"].AsInt32() : 0;
        string itemId = item.ContainsKey("id") ? item["id"].AsString() : "";

        // A journey item carries an "effects" bundle (several tuned effects); a built-in item is a
        // single kind. Push one active effect per effect in the bundle (all sharing the item's
        // duration), else the single kind. Consumers match on `kind`, so N entries apply independently.
        var bundle = source.ContainsKey("effects") ? source["effects"].AsGodotArray() : null;
        if (bundle != null && bundle.Count > 0)
        {
            foreach (var effVar in bundle)
                _active.Add(_MakeActiveEffect(itemId, displayName, effVar.AsGodotDictionary(), duration));
        }
        else
        {
            _active.Add(_MakeActiveEffect(itemId, displayName, source, duration));
        }

        EmitSignal(SignalName.InventoryChanged);
        EmitSignal(SignalName.ActiveEffectsChanged);
        return true;
    }

    // Builds one active-effect entry from an effect source (a built-in item or a bundle effect): the
    // timing fields plus every tuning param (factor/min/max/…) carried through generically, so any
    // kind's params reach the consumers. Meta keys (name/price/category/…) are skipped.
    private Dictionary _MakeActiveEffect(string id, string name, Dictionary src, int duration)
    {
        string kind = src.ContainsKey("kind") ? src["kind"].AsString() : "";
        // coin_jackpot / coin_penalty are settled at the NEXT round end (GameLoop reads and then
        // consumes them there), NOT on a wall clock. They must outlast the item's timer — a short
        // bundle duration (default 30s) would otherwise drop the coin effect before the round paid
        // out, so nothing applied. They persist until consumed; every other kind stays timed.
        bool persistToRoundEnd = kind == "coin_jackpot" || kind == "coin_penalty";
        var effect = new Dictionary
        {
            ["id"] = id,
            ["name"] = name,
            ["kind"] = src.ContainsKey("kind") ? src["kind"] : "",
            ["duration_ms"] = duration,
            ["end_time_ms"] = persistToRoundEnd ? double.MaxValue : _nowMs + duration,
            ["start_time_ms"] = _nowMs,
        };
        foreach (var k in src.Keys)
        {
            var ks = k.AsString();
            if (ks != "kind" && ks != "name" && ks != "desc" && ks != "description"
                && ks != "id" && ks != "duration_ms" && ks != "price"
                && ks != "category" && ks != "image" && ks != "effects")
                effect[ks] = src[k];
        }
        return effect;
    }

    // Picks a random modifier dict from the registry for the Wildcard item.
    // Excludes the wildcard itself and coin_jackpot — the latter's payout relies
    // on a long lifetime that the wildcard's shorter duration would cut short.
    private Dictionary _RollWildcard()
    {
        var pool = new List<Dictionary>();
        foreach (var key in _registry.Keys)
        {
            var d = _registry[key].AsGodotDictionary();
            string kind = d.ContainsKey("kind") ? d["kind"].AsString() : "";
            if (kind != "" && kind != "wildcard" && kind != "coin_jackpot")
                pool.Add(d);
        }
        if (pool.Count == 0)
            return new Dictionary();
        return pool[(int)(GD.Randi() % (uint)pool.Count)];
    }

    // --- Active effects -------------------------------------------------------

    public Array GetActiveEffects()
    {
        var activeEffects = new Array();
        foreach (var fx in _active)
            activeEffects.Add(fx);
        foreach (var fx in _bossEffects)
            activeEffects.Add(fx);

        return activeEffects;
    }

    // Clears player-activated effects only — leaves boss effects and owned
    // inventory items untouched. Used to give a boss round a clean slate.
    public void ClearActiveEffects()
    {
        if (_active.Count == 0)
            return;
        _active.Clear();
        EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // Installs a set of boss-round forced effects. Each entry must be a complete
    // effect dictionary (kind + params + display name). They apply for the whole
    // boss round and are removed with ClearBossEffects().
    public void AddBossEffects(Array effects)
    {
        foreach (var fx in effects)
        {
            if (fx.VariantType == Variant.Type.Dictionary)
                _bossEffects.Add(fx.AsGodotDictionary());
        }
        EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // Removes all boss-round forced effects. Called when a boss round ends.
    public void ClearBossEffects()
    {
        if (_bossEffects.Count == 0)
            return;
        _bossEffects.Clear();
        EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // Key stamped onto boss effects installed by AddBossEffectsFrom, so the same set can be lifted
    // again later. Underscore-prefixed like the other internal bookkeeping keys (_ref).
    private const string SourceIdKey = "_source_id";

    // Installs boss effects tagged with `sourceId`, so they can be removed as a group later without
    // disturbing anything else. This is what lets a BOSS TIMELINE apply an effect for a bounded WINDOW:
    // AddBossEffectsFrom when the window opens, RemoveBossEffectsFrom when it closes. Plain
    // AddBossEffects stays the whole-round path and is untouched.
    //
    // Each entry is DUPLICATED before tagging: the caller's dictionary is authored data that may be
    // reused (a preset dropped on the timeline twice), and stamping the original would leak this
    // bookkeeping back into it.
    public void AddBossEffectsFrom(string sourceId, Array effects)
    {
        bool added = false;
        foreach (var fx in effects)
        {
            if (fx.VariantType != Variant.Type.Dictionary)
                continue;
            var copy = fx.AsGodotDictionary().Duplicate(true);
            copy[SourceIdKey] = sourceId;
            _bossEffects.Add(copy);
            added = true;
        }

        if (added)
            EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // Removes every boss effect installed under `sourceId`. Untagged effects — the whole-round set from
    // AddBossEffects — are never touched, so closing a timeline window cannot strip the round's own
    // forced modifiers. A no-op when that source has nothing installed (a window closing twice, or one
    // whose effects were already cleared at round end).
    public void RemoveBossEffectsFrom(string sourceId)
    {
        bool removed = false;
        for (int i = _bossEffects.Count - 1; i >= 0; i--)
        {
            if (
                _bossEffects[i].ContainsKey(SourceIdKey)
                && _bossEffects[i][SourceIdKey].AsString() == sourceId
            )
            {
                _bossEffects.RemoveAt(i);
                removed = true;
            }
        }

        if (removed)
            EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // Immediately removes every active effect of the given kind. Used by GameLoop
    // to consume coin_jackpot effects right after they pay out, so a single
    // jackpot only ever doubles one round's reward.
    public void ConsumeEffects(string kind)
    {
        bool removed = false;
        for (int i = _active.Count - 1; i >= 0; i--)
        {
            if (_active[i].ContainsKey("kind") && _active[i]["kind"].AsString() == kind)
            {
                _active.RemoveAt(i);
                removed = true;
            }
        }

        if (removed)
            EmitSignal(SignalName.ActiveEffectsChanged);
    }

    // Remaining seconds for the chip countdown text. Returns 0 if expired.
    public double GetRemainingSeconds(Dictionary effect)
    {
        double end = effect.ContainsKey("end_time_ms") ? effect["end_time_ms"].AsDouble() : 0.0;
        return System.Math.Max(0.0, (end - _nowMs) / 1000.0);
    }
}
