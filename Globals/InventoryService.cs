using Godot;
using Godot.Collections;
using System.Collections.Generic;

public partial class InventoryService : Node
{
	[Signal] public delegate void InventoryChangedEventHandler();
	[Signal] public delegate void ActiveEffectsChangedEventHandler();

	// ---------------------------------------------------------------------------
	// Item registry
	// Loaded from res://data/shop_items.json on startup. Edit that file to tune
	// balance without touching C#. Falls back to hardcoded defaults if the file
	// is missing or malformed.
	// ---------------------------------------------------------------------------

	// Non-static so it is populated once the node is ready (autoload order is safe).
	private Dictionary _registry = new Dictionary();

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
						var d  = item.AsGodotDictionary();
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
			["id"]          = "long_game",
			["name"]        = "The Long Game",
			["description"] = "Expands the funscript stroke length by 20%.",
			["category"]    = "modifier",
			["price"]       = 30,
			["duration_ms"] = 30000,
			["kind"]        = "scale",
			["factor"]      = 1.2f,
		};
		_registry["cock_lock"] = new Dictionary
		{
			["id"]          = "cock_lock",
			["name"]        = "Cock Lock",
			["description"] = "Ignores funscript playback for 10 seconds.",
			["category"]    = "modifier",
			["price"]       = 25,
			["duration_ms"] = 10000,
			["kind"]        = "block",
		};
		_registry["shrink_ray"] = new Dictionary
		{
			["id"]          = "shrink_ray",
			["name"]        = "Shrink Ray",
			["description"] = "Reduces the funscript stroke length by 20%.",
			["category"]    = "modifier",
			["price"]       = 40,
			["duration_ms"] = 30000,
			["kind"]        = "scale",
			["factor"]      = 0.8f,
		};
		_registry["final_inch"] = new Dictionary
		{
			["id"]          = "final_inch",
			["name"]        = "The Final Inch",
			["description"] = "Confines the script to only the top 50% of the stroke range.",
			["category"]    = "modifier",
			["price"]       = 35,
			["duration_ms"] = 25000,
			["kind"]        = "clamp",
			["min"]         = 50,
			["max"]         = 100,
		};
		_registry["low_tide"] = new Dictionary
		{
			["id"]          = "low_tide",
			["name"]        = "Low Tide",
			["description"] = "Confines the script to only the bottom 50% of the stroke range.",
			["category"]    = "modifier",
			["price"]       = 35,
			["duration_ms"] = 25000,
			["kind"]        = "clamp",
			["min"]         = 0,
			["max"]         = 50,
		};
		_registry["mirror"] = new Dictionary
		{
			["id"]          = "mirror",
			["name"]        = "Mirror",
			["description"] = "Inverts all stroke positions for 30 seconds. Up becomes down.",
			["category"]    = "modifier",
			["price"]       = 30,
			["duration_ms"] = 30000,
			["kind"]        = "reverse",
		};
		_registry["blackout"] = new Dictionary
		{
			["id"]          = "blackout",
			["name"]        = "Blackout",
			["description"] = "Hides the video for 30 seconds. The device keeps going in the dark.",
			["category"]    = "modifier",
			["price"]       = 20,
			["duration_ms"] = 30000,
			["kind"]        = "blackout",
		};
		_registry["score_rush"] = new Dictionary
		{
			["id"]          = "score_rush",
			["name"]        = "Score Rush",
			["description"] = "Doubles score earned from every stroke for 30 seconds.",
			["category"]    = "modifier",
			["price"]       = 40,
			["duration_ms"] = 30000,
			["kind"]        = "score_multiplier",
			["factor"]      = 2.0f,
		};
		_registry["jackpot"] = new Dictionary
		{
			["id"]          = "jackpot",
			["name"]        = "Jackpot",
			["description"] = "Doubles the coin reward at the end of this round.",
			["category"]    = "modifier",
			["price"]       = 50,
			["duration_ms"] = 300000,
			["kind"]        = "coin_jackpot",
			["factor"]      = 2.0f,
		};
	}

	// --- Registry access -------------------------------------------------------

	// Returns all registered item IDs in insertion order.
	public Array GetAllItemIds()
	{
		var ids = new Array();

		foreach (var key in _registry.Keys)
			ids.Add(key);

		return ids;
	}

	// Returns the data dictionary for the given item ID, or an empty dict if unknown.
	public Dictionary GetItemData(string id)
	{
		if (id != null && _registry.ContainsKey(id))
			return _registry[id].AsGodotDictionary();
		return new Dictionary();
	}

	// ---------------------------------------------------------------------------
	// Inventory (owned, not-yet-activated items)
	// ---------------------------------------------------------------------------

	private readonly List<Dictionary> _items = new();

	// Active effects: one entry per activation, with absolute end time on engine clock (ms).
	private readonly List<Dictionary> _active = new();

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

	// Removes the item at slotIndex and starts its effect timer immediately.
	public bool ActivateItem(int slotIndex)
	{
		if (slotIndex < 0 || slotIndex >= _items.Count)
			return false;

		var item = _items[slotIndex];
		_items.RemoveAt(slotIndex);

		int duration = item.ContainsKey("duration_ms") ? item["duration_ms"].AsInt32() : 0;
		var effect = new Dictionary
		{
			["id"]            = item.ContainsKey("id")   ? item["id"]   : "",
			["name"]          = item.ContainsKey("name") ? item["name"] : "",
			["kind"]          = item.ContainsKey("kind") ? item["kind"] : "",
			["duration_ms"]   = duration,
			["end_time_ms"]   = _nowMs + duration,
			["start_time_ms"] = _nowMs,
		};
		// Copy effect params used by FunscriptPlayer.
		if (item.ContainsKey("factor")) effect["factor"] = item["factor"];
		if (item.ContainsKey("min"))    effect["min"]    = item["min"];
		if (item.ContainsKey("max"))    effect["max"]    = item["max"];

		_active.Add(effect);
		EmitSignal(SignalName.InventoryChanged);
		EmitSignal(SignalName.ActiveEffectsChanged);
		return true;
	}

	// --- Active effects -------------------------------------------------------

	public Array GetActiveEffects()
	{
		var activeEffects = new Array();
		foreach (var fx in _active)
			activeEffects.Add(fx);

		return activeEffects;
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
