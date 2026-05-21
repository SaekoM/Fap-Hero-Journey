using Godot;
using System;
using System.Collections.Generic;
using System.Linq;

// Tracks stroke-based scoring across rounds. Designed to be called from
// FunscriptPlayer on every dispatched stroke. Item-based modifiers set
// SetMultiplier() for the duration of the effect and clear it afterward.
public partial class ScoreService : Node
{
	[Signal] public delegate void ScoreChangedEventHandler(int totalScore);

	// Bucket thresholds (inclusive upper bound, 0–100 position delta)
	private const int SmallMax  = 20;
	private const int MediumMax = 70;

	private const int SmallPts  = 1;
	private const int MediumPts = 3;
	private const int LargePts  = 5;

	private struct RoundData
	{
		public int Score;
		public int SmallStrokes;
		public int MediumStrokes;
		public int LargeStrokes;
		public int ActionCount;
	}

	private List<RoundData> _rounds = new();
	private RoundData _current;
	private double _multiplier = 1.0;

	public override void _Ready()
	{
		var inv = GetNode<InventoryService>("/root/InventoryService");
		inv.ActiveEffectsChanged += _SyncMultiplier;
	}

	// Recompute the score multiplier from active score_multiplier effects.
	// Called whenever the active-effect list changes so the multiplier is always
	// current without polling every frame.
	private void _SyncMultiplier()
	{
		var inv = GetNode<InventoryService>("/root/InventoryService");
		double mult = 1.0;
		foreach (var fx in inv.GetActiveEffects())
		{
			var d = fx.AsGodotDictionary();
			if (d.ContainsKey("kind") && d["kind"].AsString() == "score_multiplier" && d.ContainsKey("factor"))
				mult *= d["factor"].AsDouble();
		}
		SetMultiplier(mult);
	}

	public int TotalScore   => _rounds.Sum(r => r.Score) + _current.Score;
	public int TotalStrokes => _rounds.Sum(r => r.SmallStrokes + r.MediumStrokes + r.LargeStrokes)
	                         + _current.SmallStrokes + _current.MediumStrokes + _current.LargeStrokes;

	public void Reset()
	{
		_rounds.Clear();
		_current = default;
		_multiplier = 1.0;
		EmitSignal(SignalName.ScoreChanged, 0);
	}

	public void StartRound()
	{
		_current = default;
	}

	public void EndRound()
	{
		_rounds.Add(_current);
		_current = default;
	}

	public void SetMultiplier(double multiplier) => _multiplier = multiplier;

	public void SetRoundActions(int count) => _current.ActionCount = count;

	public void AddStroke(int amplitude)
	{
		int basePoints = amplitude switch
		{
			<= SmallMax  => SmallPts,
			<= MediumMax => MediumPts,
			_            => LargePts,
		};

		int points = (int)Math.Max(1, Math.Round(basePoints * _multiplier));
		_current.Score += points;

		if (amplitude <= SmallMax)
			_current.SmallStrokes++;
		else if (amplitude <= MediumMax)
			_current.MediumStrokes++;
		else
			_current.LargeStrokes++;

		EmitSignal(SignalName.ScoreChanged, TotalScore);
	}

	// Returns completed rounds only (not the current in-progress round).
	// Each Dictionary has keys: score, small, medium, large (all int).
	public Godot.Collections.Array<Godot.Collections.Dictionary> GetRoundBreakdowns()
	{
		var result = new Godot.Collections.Array<Godot.Collections.Dictionary>();
		foreach (var r in _rounds)
		{
			var d = new Godot.Collections.Dictionary
			{
				["score"]   = r.Score,
				["small"]   = r.SmallStrokes,
				["medium"]  = r.MediumStrokes,
				["large"]   = r.LargeStrokes,
				["actions"] = r.ActionCount,
			};
			result.Add(d);
		}
		return result;
	}
}
