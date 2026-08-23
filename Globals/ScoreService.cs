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
    private const int SmallMax = 20;
    private const int MediumMax = 70;

    private const int SmallPts = 1;
    private const int MediumPts = 3;
    private const int LargePts = 5;

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
        var inventory = GetNode<InventoryService>("/root/InventoryService");
        double multiplier = 1.0;
        foreach (var effectVariant in inventory.GetActiveEffects())
        {
            var effect = effectVariant.AsGodotDictionary();
            if (effect.ContainsKey("kind") && effect["kind"].AsString() == "score_multiplier" && effect.ContainsKey("factor"))
                multiplier *= effect["factor"].AsDouble();
        }
        SetMultiplier(multiplier);
    }

    // The round IN PROGRESS, for the boss encounter's conditions. Deliberately separate from the
    // Total* properties: a fork asking "are they struggling?" means struggling in THIS fight, and a
    // running total that carries every earlier round would answer a different question entirely.
    // The scoring thresholds, exposed so the encounter editor can work out what a full pass of a round
    // is worth WITHOUT retyping them. A second copy in GDScript would drift silently the first time
    // scoring was retuned, and the number an author tunes their boss against would quietly go wrong.
    public int SmallStrokeMax => SmallMax;
    public int MediumStrokeMax => MediumMax;
    public int SmallStrokePoints => SmallPts;
    public int MediumStrokePoints => MediumPts;
    public int LargeStrokePoints => LargePts;

    public int CurrentRoundScore => _current.Score;
    public int CurrentRoundSmallStrokes => _current.SmallStrokes;
    public int CurrentRoundMediumStrokes => _current.MediumStrokes;
    public int CurrentRoundLargeStrokes => _current.LargeStrokes;
    public int CurrentRoundStrokes =>
        _current.SmallStrokes + _current.MediumStrokes + _current.LargeStrokes;

    public int TotalScore => _rounds.Sum(r => r.Score) + _current.Score;
    // Score of the most recently completed round (0 before any round ends). Used
    // by score-based Conditional forks.
    public int LastRoundScore => _rounds.Count > 0 ? _rounds[^1].Score : 0;
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

    // Ends the round WITHOUT banking it: a skipped round scores nothing, so the partial score
    // accrued before the skip is thrown away rather than added to the run. LastRoundScore keeps
    // reporting the previous completed round, which is what score-based forks should read.
    public void DiscardRound()
    {
        _current = default;
    }

    public void SetMultiplier(double multiplier) => _multiplier = multiplier;

    // Test-play helper: injects a synthetic completed round with the given score
    // so score-based Conditional forks can be exercised from a chosen starting
    // point (LastRoundScore then returns this value). Not used in normal play.
    public void SeedLastRoundScore(int score)
    {
        _rounds.Add(new RoundData { Score = score });
        EmitSignal(SignalName.ScoreChanged, TotalScore);
    }

    // Save/resume bridge. Captures totals at the moment of save so the end
    // screen can display the same cumulative numbers after a resumed run.
    // Counts are persisted as a single synthetic "round" rather than the
    // per-round bucket breakdown — saves don't need that granularity for
    // the resume case and it keeps the schema small.
    public Godot.Collections.Dictionary CaptureSaveData()
    {
        return new Godot.Collections.Dictionary
        {
            ["score"] = TotalScore,
            ["strokes"] = TotalStrokes,
        };
    }

    // Restores the cumulative totals captured by CaptureSaveData. Stuffs them
    // into a single synthetic round so TotalScore / TotalStrokes still return
    // the right numbers and the next StartRound() / EndRound() cycle continues
    // adding on top normally.
    public void LoadFromSave(Godot.Collections.Dictionary saveData)
    {
        _rounds.Clear();
        _current = default;
        var restored = new RoundData
        {
            Score = saveData.ContainsKey("score") ? saveData["score"].AsInt32() : 0,
            SmallStrokes = saveData.ContainsKey("strokes") ? saveData["strokes"].AsInt32() : 0,
        };
        _rounds.Add(restored);
        _multiplier = 1.0;
        EmitSignal(SignalName.ScoreChanged, TotalScore);
    }

    public void SetRoundActions(int count) => _current.ActionCount = count;

    public void AddStroke(int amplitude)
    {
        int basePoints = amplitude switch
        {
            <= SmallMax => SmallPts,
            <= MediumMax => MediumPts,
            _ => LargePts,
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

    // Docks points from the current round's score (pause penalty). Clamped at 0 so
    // a penalty can never eat into previously banked rounds. Emits ScoreChanged so
    // the HUD reflects the drain live.
    public void PenalizeScore(int points)
    {
        if (points <= 0)
            return;
        _current.Score = Math.Max(0, _current.Score - points);
        EmitSignal(SignalName.ScoreChanged, TotalScore);
    }

    // Returns completed rounds only (not the current in-progress round).
    // Each Dictionary has keys: score, small, medium, large (all int).
    public Godot.Collections.Array<Godot.Collections.Dictionary> GetRoundBreakdowns()
    {
        var breakdowns = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        foreach (var round in _rounds)
        {
            var breakdown = new Godot.Collections.Dictionary
            {
                ["score"] = round.Score,
                ["small"] = round.SmallStrokes,
                ["medium"] = round.MediumStrokes,
                ["large"] = round.LargeStrokes,
                ["actions"] = round.ActionCount,
            };
            breakdowns.Add(breakdown);
        }
        return breakdowns;
    }
}
