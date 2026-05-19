using Godot;
using Godot.Collections;
using System.Collections.Generic;

public partial class InventoryService : Node
{
	[Signal] public delegate void InventoryChangedEventHandler();
	[Signal] public delegate void ActiveEffectsChangedEventHandler();

	// Central item registry. The "kind" field drives FunscriptPlayer's modifier pipeline:
	//   "block"  – drop actions entirely while active
	//   "scale"  – multiply stroke amplitude around centre (factor)
	//   "clamp"  – compress 0–100 position range into [min, max]
	private static readonly Dictionary _registry = new Dictionary
	{
		["long_game"] = new Dictionary
		{
			["id"]          = "long_game",
			["name"]        = "The Long Game",
			["description"] = "Expands the funscript stroke length by 30%.",
			["category"]    = "modifier",
			["price"]       = 40,
			["duration_ms"] = 30000,
			["kind"]        = "scale",
			["factor"]      = 1.3f,
			["icon_path"]   = "",
		},
		["cock_lock"] = new Dictionary
		{
			["id"]          = "cock_lock",
			["name"]        = "Cock Lock",
			["description"] = "Ignores funscript playback for 10 seconds.",
			["category"]    = "modifier",
			["price"]       = 25,
			["duration_ms"] = 10000,
			["kind"]        = "block",
			["icon_path"]   = "",
		},
		["shrink_ray"] = new Dictionary
		{
			["id"]          = "shrink_ray",
			["name"]        = "Shrink Ray",
			["description"] = "Reduces the funscript stroke length by 20%.",
			["category"]    = "modifier",
			["price"]       = 30,
			["duration_ms"] = 30000,
			["kind"]        = "scale",
			["factor"]      = 0.8f,
			["icon_path"]   = "",
		},
		["final_inch"] = new Dictionary
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
			["icon_path"]   = "",
		},
		["low_tide"] = new Dictionary
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
			["icon_path"]   = "",
		},
	};

	// Owned but not-yet-activated items (one dict per slot — duplicates allowed).
	private readonly List<Dictionary> _items = new();

	// Active effects: one entry per activation, with absolute end time on engine clock (ms).
	private readonly List<Dictionary> _active = new();

	private double _nowMs = 0.0;

	public override void _Process(double delta)
	{
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
		EmitSignal(SignalName.InventoryChanged);
		EmitSignal(SignalName.ActiveEffectsChanged);
	}

	// --- Registry access -----------------------------------------------------

	public static Array GetAllItemIds()
	{
		var ids = new Array();
		foreach (var key in _registry.Keys)
			ids.Add(key);
		return ids;
	}

	public static Dictionary GetItemData(string id)
	{
		if (id != null && _registry.ContainsKey(id))
			return _registry[id].AsGodotDictionary();
		return new Dictionary();
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
		if (data.Count == 0) return;
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
			["id"]          = item.ContainsKey("id") ? item["id"] : "",
			["name"]        = item.ContainsKey("name") ? item["name"] : "",
			["kind"]        = item.ContainsKey("kind") ? item["kind"] : "",
			["duration_ms"] = duration,
			["end_time_ms"] = _nowMs + duration,
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

	// --- Active effects ------------------------------------------------------

	public Array GetActiveEffects()
	{
		var arr = new Array();
		foreach (var fx in _active)
			arr.Add(fx);
		return arr;
	}

	// Remaining seconds for the chip countdown text. Returns 0 if expired.
	public double GetRemainingSeconds(Dictionary effect)
	{
		double end = effect.ContainsKey("end_time_ms") ? effect["end_time_ms"].AsDouble() : 0.0;
		return System.Math.Max(0.0, (end - _nowMs) / 1000.0);
	}
}
