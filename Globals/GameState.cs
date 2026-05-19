using Godot;
using Godot.Collections;
using System.Collections.Generic;
using System.Linq;

public partial class GameState : Node
{
	public Dictionary Journey { get; private set; } = new Dictionary();

	private List<Dictionary> _sequence = new();
	private int _seqIndex = 0;

	// Current position in the sequence (includes fork markers before resolution).
	public int RoundIndex => _seqIndex;

	// 1-based number of the current round among round-type items only.
	public int RoundNumber => _sequence
		.Take(_seqIndex + 1)
		.Count(item => item["type"].AsString() == "round");

	public void StartJourney(Dictionary data)
	{
		Journey   = data;
		_seqIndex = 0;
		_sequence = BuildSequence(data);
	}

	private static List<Dictionary> BuildSequence(Dictionary data)
	{
		var items = new List<(int SortKey, Dictionary Data)>();

		var rounds = data.ContainsKey("rounds") ? data["rounds"].AsGodotArray() : new Array();
		foreach (var r in rounds)
		{
			var rd = r.AsGodotDictionary();
			int order = rd.ContainsKey("order") ? rd["order"].AsInt32() : 0;
			items.Add((order * 3, new Dictionary { ["type"] = "round", ["data"] = rd }));
		}

		var shops = data.ContainsKey("shops") ? data["shops"].AsGodotArray() : new Array();
		foreach (var s in shops)
		{
			Dictionary sd;
			int afterOrder;
			if (s.VariantType == Variant.Type.Dictionary)
			{
				sd = s.AsGodotDictionary();
				afterOrder = sd.ContainsKey("after_order") ? sd["after_order"].AsInt32() : 0;
			}
			else
			{
				// Legacy format: "shops": [orderNum, ...]
				afterOrder = s.AsInt32();
				sd = new Dictionary { ["after_order"] = afterOrder };
			}
			items.Add((afterOrder * 3 + 1, new Dictionary { ["type"] = "shop", ["data"] = sd }));
		}

		var forks = data.ContainsKey("forks") ? data["forks"].AsGodotArray() : new Array();
		foreach (var f in forks)
		{
			var fd = f.AsGodotDictionary();
			int afterOrder = fd.ContainsKey("after_order") ? fd["after_order"].AsInt32() : 0;
			items.Add((afterOrder * 3 + 2, new Dictionary { ["type"] = "fork", ["data"] = fd }));
		}

		items.Sort((a, b) => a.SortKey.CompareTo(b.SortKey));
		return items.Select(i => i.Data).ToList();
	}

	public Dictionary CurrentItem()
	{
		if (_seqIndex >= _sequence.Count) return new Dictionary();
		return _sequence[_seqIndex];
	}

	public string CurrentItemType()
	{
		var item = CurrentItem();
		return item.ContainsKey("type") ? item["type"].AsString() : "round";
	}

	// Returns the current round's data dict. Empty if current item is a fork or sequence is done.
	public Dictionary CurrentRound()
	{
		var item = CurrentItem();
		if (item.ContainsKey("type") && item["type"].AsString() == "round")
			return item["data"].AsGodotDictionary();
		return new Dictionary();
	}

	// Returns the current fork's data dict. Empty if current item is a round.
	public Dictionary CurrentFork()
	{
		var item = CurrentItem();
		if (item.ContainsKey("type") && item["type"].AsString() == "fork")
			return item["data"].AsGodotDictionary();
		return new Dictionary();
	}

	// Returns the current shop's data dict. Empty if current item is not a shop.
	public Dictionary CurrentShop()
	{
		var item = CurrentItem();
		if (item.ContainsKey("type") && item["type"].AsString() == "shop")
			return item["data"].AsGodotDictionary();
		return new Dictionary();
	}

	// Replaces the current fork marker with the chosen path's rounds, then leaves
	// _seqIndex pointing at the first round of the chosen path.
	public void ResolveFork(int pathIndex)
	{
		var item = CurrentItem();
		if (!item.ContainsKey("type") || item["type"].AsString() != "fork")
			return;

		var forkData = item["data"].AsGodotDictionary();
		if (!forkData.ContainsKey("paths"))
			return;

		var paths = forkData["paths"].AsGodotArray();
		if (pathIndex < 0 || pathIndex >= paths.Count)
			pathIndex = 0;

		var chosen       = paths[pathIndex].AsGodotDictionary();
		var chosenRounds = chosen.ContainsKey("rounds") ? chosen["rounds"].AsGodotArray() : new Array();
		var chosenShops  = chosen.ContainsKey("shops")  ? chosen["shops"].AsGodotArray()  : new Array();

		// Interleave path rounds and shops by the same sort-key scheme as
		// BuildSequence so authoring order is preserved on resolution.
		var subItems = new List<(int SortKey, Dictionary Data)>();
		foreach (var r in chosenRounds)
		{
			var rd = r.AsGodotDictionary();
			int order = rd.ContainsKey("order") ? rd["order"].AsInt32() : 0;
			subItems.Add((order * 3, new Dictionary { ["type"] = "round", ["data"] = rd }));
		}
		foreach (var s in chosenShops)
		{
			var sd = s.AsGodotDictionary();
			int afterOrder = sd.ContainsKey("after_order") ? sd["after_order"].AsInt32() : 0;
			subItems.Add((afterOrder * 3 + 1, new Dictionary { ["type"] = "shop", ["data"] = sd }));
		}
		subItems.Sort((a, b) => a.SortKey.CompareTo(b.SortKey));

		_sequence.RemoveAt(_seqIndex);
		for (int i = subItems.Count - 1; i >= 0; i--)
		{
			_sequence.Insert(_seqIndex, subItems[i].Data);
		}
		// _seqIndex now points at the first item of the chosen path.
	}

	public void Advance() => _seqIndex++;

	public bool IsSequenceDone() => _seqIndex >= _sequence.Count;

	// Legacy alias — GameLoop checks this before advancing.
	public bool IsLastRound() => _seqIndex >= _sequence.Count - 1;

	// Count of round-type items currently in the sequence (grows after fork resolution).
	public int TotalRounds() => _sequence.Count(item => item["type"].AsString() == "round");

	public Array GetPlayedRounds()
	{
		var result = new Array();
		foreach (var item in _sequence)
		{
			if (item.ContainsKey("type") && item["type"].AsString() == "round")
				result.Add(item["data"]);
		}
		return result;
	}

}
