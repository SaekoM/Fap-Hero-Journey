using Godot;
using Godot.Collections;
using System.Collections.Generic;
using System.Linq;

// Runtime journey driver. Walks the DAG produced by JourneyScanner.parse_graph
// ({start, nodes} + journey meta): the current node id advances along out-edges,
// and a fork node resolves by picking one of its edges. This replaced the old
// pre-spliced sequence + fork_end sentinel model — migrated journeys play identically.
public partial class GameState : Node
{
    // The combined dict from parse_graph: journey meta + the graph under start/nodes
    // (+ the legacy nested arrays during the Phase-2 transition, which the map/catalogue
    // still read). The runtime only touches start/nodes.
    public Dictionary Journey { get; private set; } = new Dictionary();

    private Dictionary _nodes = new Dictionary();   // id -> { type, data, out:[{to,...}] }
    private string _currentId = "";

    // Boolean run flags: set by playing a node (data.set_flags) or taking a fork choice (edge.set_flags),
    // read by flag-conditional forks (HasFlag), and carried in the save record. Cleared on a fresh start.
    private HashSet<string> _flags = new();

    // Fired when a counter's value changes via set_counters (NOT on save-restore or seeding, which
    // reinstate values silently). GameLoop shows the transient top-right pop for journey-"shown"
    // counters from this. `delta` is the signed change; `value` the new total.
    [Signal]
    public delegate void CounterChangedEventHandler(string name, int value, int delta);

    // Named integer counters (belt notches, arousal, satisfied partners, …): the numeric sibling of
    // _flags. Bumped by a node's / fork edge's set_counters ({name: delta}), read by counter-conditional
    // forks (CounterValue) and optionally shown on the HUD, and carried in the save record. A missing
    // counter reads as 0, so a threshold works before anything has bumped it. Cleared on a fresh start.
    private System.Collections.Generic.Dictionary<string, int> _counters = new();

    // Per-loop iteration counts (loop node id → how many times its body has run this pass). Bumped each time
    // the walker reaches a loop node; reset to 0 when that loop exits (so a later re-entry counts fresh).
    // Rides the save record so a resume mid-loop keeps its iteration progress. Cleared on a fresh start.
    private System.Collections.Generic.Dictionary<string, int> _loopCounts = new();

    // Node ids the player has landed on this run (added in EnterCurrent). Drives the map's fog-of-war
    // reveal and rides the save record so a resumed run keeps what was found. Cleared on a fresh start —
    // discovery is per-run.
    private HashSet<string> _discovered = new();

    // Video clips already drawn by NO-REPEAT pool rounds this run (keyed by pooled video_path). A
    // no-repeat pool skips clips in here, so two copies of the same pool don't show the same video.
    // Rides the save record (per-run, but persists across resume). Cleared on a fresh start.
    private HashSet<string> _playedPoolClips = new();

    // Round nodes entered so far this run = the 1-based "current round number". A DAG is
    // acyclic, so each node is entered at most once — no double counting.
    private int _roundsEntered = 0;

    // Chronological play log (shape unchanged): fork_choice / round entries. "depth" is the
    // node's tree-nesting depth (stamped by build_graph), reproducing the old fork_depth so
    // the end screen indents nested forks. Author-rewired convergence (Phase 3) could make
    // depth ambiguous, but migrated tree journeys are exact.
    private List<Dictionary> _playLog = new();

    // 1-based number of the current round among round-type nodes entered so far.
    public int RoundNumber => _roundsEntered;

    public void StartJourney(Dictionary data)
    {
        Journey = data;
        _nodes = data.ContainsKey("nodes") ? data["nodes"].AsGodotDictionary() : new Dictionary();
        _currentId = data.ContainsKey("start") ? data["start"].AsString() : "";
        _roundsEntered = 0;
        _playLog.Clear();
        _flags.Clear();
        _counters.Clear();
        _loopCounts.Clear();
        _discovered.Clear();
        _playedPoolClips.Clear();
        EnterCurrent();
    }

    // Test-play "from here": teleport the walker to a node id (the DAG lets us jump
    // without replaying fork decisions — we just set the current node and recount).
    // Returns false, leaving the position at the journey start, when the id isn't in
    // the graph (e.g. a stale selection). RoundNumber restarts from this node.
    public bool SeekToNode(string nodeId)
    {
        if (nodeId == "" || !_nodes.ContainsKey(nodeId))
            return false;
        _currentId = nodeId;
        _roundsEntered = 0;
        _playLog.Clear();
        _flags.Clear();
        _counters.Clear();
        _loopCounts.Clear();
        _discovered.Clear();
        _playedPoolClips.Clear();
        EnterCurrent();
        return true;
    }

    // ---------------------------------------------------------------------------
    // Walking
    // ---------------------------------------------------------------------------

    private Dictionary NodeOf(string id) =>
        (id != "" && _nodes.ContainsKey(id)) ? _nodes[id].AsGodotDictionary() : new Dictionary();

    private Array OutEdges(string id)
    {
        var n = NodeOf(id);
        return n.ContainsKey("out") ? n["out"].AsGodotArray() : new Array();
    }

    private string TypeOf(string id)
    {
        var n = NodeOf(id);
        return n.ContainsKey("type") ? n["type"].AsString() : "";
    }

    // Bumps the round counter when the node we just landed on is a round.
    private void CountIfRound()
    {
        if (TypeOf(_currentId) == "round")
            _roundsEntered++;
    }

    // Landing on the current node: bump the round count and apply any flags its data sets.
    // Flags apply on ARRIVAL (a "you've been here" mark). COUNTERS do not — they are bestowed when the
    // node COMPLETES (round end, storyboard/shop close), via ApplyCurrentNodeCounters called by GameLoop.
    // That gives a counter the "you finished this → tally it" meaning the author expects, and keeps its
    // HUD pop from being buried under the storyboard/shop overlay that opens the instant you arrive.
    private void EnterCurrent()
    {
        if (_currentId != "") _discovered.Add(_currentId);   // map fog-of-war: this node is now discovered
        CountIfRound();
        var n = NodeOf(_currentId);
        if (n.ContainsKey("data"))
            ApplyFlags(n["data"].AsGodotDictionary());
    }

    // Bestows the CURRENT node's set_counters — GameLoop calls this at a node's completion (round end,
    // storyboard/shop close, checkpoint continue), so counters land at the END of a node, not on arrival.
    // Fork-edge counters keep their own path (ResolveFork), since a fork "completes" when a choice is made.
    public void ApplyCurrentNodeCounters()
    {
        var n = NodeOf(_currentId);
        if (n.ContainsKey("data"))
        {
            var d = n["data"].AsGodotDictionary();
            ApplyCounters(d);
            ApplyItemRemovals(d);  // node's remove_items — bestowed at completion, alongside counters
        }
    }

    // Adds src["set_flags"] to the run's flag set and removes src["clear_flags"] from it (a node's data or
    // a fork edge). clear_flags carries the "-flag" entries from the SETS FLAGS field. Both are idempotent
    // (add/remove of a set), so a resume that re-enters this node is harmless — unlike ApplyItemRemovals.
    private void ApplyFlags(Dictionary src)
    {
        if (src.ContainsKey("set_flags"))
            foreach (var f in src["set_flags"].AsGodotArray())
            {
                var name = f.AsString();
                if (name != "") _flags.Add(name);
            }
        if (src.ContainsKey("clear_flags"))
            foreach (var f in src["clear_flags"].AsGodotArray())
            {
                var name = f.AsString();
                if (name != "") _flags.Remove(name);
            }
    }

    // Removes one held copy of each id in src["remove_items"] (InventoryService.ConsumeItem). Applied ONLY
    // at node COMPLETION / fork CHOICE — never on arrival — so a resume re-entering a node can't re-consume
    // (removal isn't idempotent). A missing item is a silent no-op.
    private void ApplyItemRemovals(Dictionary src)
    {
        if (!src.ContainsKey("remove_items")) return;
        var inv = GetNodeOrNull<InventoryService>("/root/InventoryService");
        if (inv == null) return;
        foreach (var it in src["remove_items"].AsGodotArray())
        {
            var id = it.AsString();
            if (id != "") inv.ConsumeItem(id);
        }
    }

    // Applies src["set_counters"] ({name: delta}) to the run's counters — the numeric analogue of
    // ApplyFlags, called for the same node-data and fork-edge sources. Deltas accumulate, so the
    // same counter bumped on several nodes sums; a delta may be negative.
    private void ApplyCounters(Dictionary src)
    {
        if (!src.ContainsKey("set_counters")) return;
        var deltas = src["set_counters"].AsGodotDictionary();
        foreach (var key in deltas.Keys)
        {
            var name = key.AsString();
            if (name == "") continue;
            var delta = deltas[key].AsInt32();
            _counters.TryGetValue(name, out var cur);
            _counters[name] = cur + delta;
            EmitSignal(SignalName.CounterChanged, name, _counters[name], delta);
        }
    }

    // Applies an item's flag/counter changes — same `set_flags` / `set_counters` shape as a node's
    // data, so a used item can flip a run flag or bump a counter (routing story branches off the
    // player's item choice). Reuses the node appliers, so a counter change still fires CounterChanged
    // for the HUD pop. GameLoop calls this when a one-shot flag/counter item effect is activated.
    public void ApplyItemFlagsCounters(Dictionary src)
    {
        ApplyFlags(src);
        ApplyCounters(src);
    }

    // Whether a run flag is currently set (used by flag-conditional fork resolution).
    public bool HasFlag(string name) => _flags.Contains(name);

    // The current value of a named counter (0 if never set) — read by counter-conditional forks and
    // the HUD.
    // Raises one run flag by name. Exists because ApplyFlags is private and its public wrapper is named
    // for items: a boss outcome setting "they beat her" is neither an item nor a node's blanket
    // set_flags, and routing it through either would misdescribe it at the call site.
    public void SetFlag(string name)
    {
        if (!string.IsNullOrEmpty(name))
            _flags.Add(name);
    }

    public int CounterValue(string name) => _counters.TryGetValue(name, out var v) ? v : 0;

    // Absolute set, for INTERNAL bookkeeping that happens to want save persistence — the boss
    // encounter's accumulated damage is the case this exists for. Deliberately does not emit
    // CounterChanged: that signal drives author-facing reactions, and a health bar ticking during a
    // fight is not a counter the author wrote or expects anything to hang off.
    public void SetCounterValue(string name, int value)
    {
        if (!string.IsNullOrEmpty(name))
            _counters[name] = value;
    }

    // Records a clip a no-repeat pool round drew, so later copies of that pool skip it.
    public void MarkPoolClipPlayed(string videoPath)
    {
        if (!string.IsNullOrEmpty(videoPath)) _playedPoolClips.Add(videoPath);
    }

    // The set of already-drawn no-repeat pool clips as a Godot set {video_path: true}, for the pure
    // GDScript weight filter (JourneyData.pool_draw_weights).
    public Dictionary PlayedPoolClips()
    {
        var d = new Dictionary();
        foreach (var p in _playedPoolClips)
            d[p] = true;
        return d;
    }

    // Test-play: pre-set flags so a Test-From-Here run can exercise flag-gated forks. Adds on top of
    // whatever the start/seek node already set.
    public void SeedFlags(Array flags)
    {
        foreach (var f in flags)
        {
            var name = f.AsString();
            if (name != "") _flags.Add(name);
        }
    }

    // Test-play companion to SeedFlags: pre-set counter values so a Test-From-Here run can exercise
    // counter-gated forks. `values` is {name: int}, set absolutely (not added) on top of whatever the
    // start/seek node already applied.
    public void SeedCounters(Dictionary values)
    {
        foreach (var key in values.Keys)
        {
            var name = key.AsString();
            if (name != "") _counters[name] = values[key].AsInt32();
        }
    }

    public Dictionary CurrentItem() => NodeOf(_currentId);

    // The current node's stable id (its graph key) — drives the journey-map marker, which
    // highlights the node by id. "" when the journey is done.
    public string CurrentNodeId() => _currentId;

    // The current node's type ("round"/"shop"/"storyboard"/"fork"); "" when the journey is
    // done. Drives GameLoop's dispatch and the map keying.
    public string CurrentItemType() => TypeOf(_currentId);

    public Dictionary CurrentRound() => DataIfType("round");
    public Dictionary CurrentShop() => DataIfType("shop");
    public Dictionary CurrentStoryboard() => DataIfType("storyboard");

    private Dictionary DataIfType(string type)
    {
        var n = NodeOf(_currentId);
        if (n.ContainsKey("type") && n["type"].AsString() == type)
            return n["data"].AsGodotDictionary();
        return new Dictionary();
    }

    // Moves the walker to the ENTRY node of the off-graph aftercare sequence (round / storyboard / …),
    // reachable only via the FINISH button. Unlike SeekToNode (test-play's "from here" reset), this
    // KEEPS the run state built up during play — the finish node plays after a real playthrough, not
    // restarted from. Its out-edges advance through the sequence like any node, until a node with no
    // exit reaches "done" → the end screen. Returns false (no state change) if the id isn't a node.
    public bool JumpToFinish(string nodeId)
    {
        if (nodeId == "" || !_nodes.ContainsKey(nodeId))
            return false;
        _currentId = nodeId;
        EnterCurrent();
        return true;
    }

    // Reconstructs the paths-shaped fork dict that ForkScreen / ForkResolver / GameLoop
    // expect, from the fork node's meta + its out-edges (one edge == one path). Empty when
    // the current node isn't a fork.
    public Dictionary CurrentFork()
    {
        var node = NodeOf(_currentId);
        if (!(node.ContainsKey("type") && node["type"].AsString() == "fork"))
            return new Dictionary();

        var data = node["data"].AsGodotDictionary();
        // Fork-level counter is the default for every choice; a choice may override it with its own
        // (per-path cond_counter), which lets one fork gate different choices on different counters.
        var forkCounter = data.ContainsKey("cond_counter") ? data["cond_counter"].AsString() : "";

        // "N ROUNDS" per choice now counts only the rounds DISTINCT to that choice — up to where this fork's
        // branches rejoin — so a shared tail after a convergence doesn't inflate every choice. Convergence =
        // any node reachable from two or more of the fork's immediate branches (see ForkConvergence).
        var branchTargets = new System.Collections.Generic.List<string>();
        foreach (var edgeVariant in OutEdges(_currentId))
            branchTargets.Add(edgeVariant.AsGodotDictionary().TryGetValue("to", out var tv) ? tv.AsString() : "");
        var convergence = ForkConvergence(branchTargets);

        var paths = new Array();
        foreach (var edgeVariant in OutEdges(_currentId))
        {
            var e = edgeVariant.AsGodotDictionary();
            var to = e.ContainsKey("to") ? e["to"].AsString() : "";
            var edgeCounter = e.ContainsKey("cond_counter") ? e["cond_counter"].AsString() : "";
            paths.Add(new Dictionary
            {
                ["name"] = e.ContainsKey("name") ? e["name"].AsString() : "",
                ["description"] = e.ContainsKey("description") ? e["description"].AsString() : "",
                ["image_path"] = e.ContainsKey("image_path") ? e["image_path"].AsString() : "",
                ["image_fit"] = e.ContainsKey("image_fit") ? e["image_fit"].AsString() : "",
                ["weight"] = e.ContainsKey("weight") ? e["weight"].AsInt32() : 1,
                ["threshold"] = e.ContainsKey("threshold") ? e["threshold"].AsInt32() : 0,
                ["required_item"] = e.ContainsKey("required_item") ? e["required_item"].AsString() : "",
                ["cost"] = e.ContainsKey("cost") ? e["cost"].AsInt32() : 0,
                ["required_flag"] = e.ContainsKey("required_flag") ? e["required_flag"].AsString() : "",
                // Effective per-choice counter: the choice's own, or the fork default when it left it blank.
                ["cond_counter"] = edgeCounter != "" ? edgeCounter : forkCounter,
                // Rounds distinct to this branch (longest path, stopping at the fork's convergence).
                // ForkScreen renders this as the "N ROUNDS" tag.
                ["round_count"] = LongestRoundPathBounded(to, convergence),
            });
        }
        return new Dictionary
        {
            ["title"] = data.ContainsKey("title") ? data["title"].AsString() : "",
            ["description"] = data.ContainsKey("description") ? data["description"].AsString() : "",
            ["resolution"] = data.ContainsKey("resolution") ? data["resolution"].AsString() : "choice",
            ["cond_metric"] = data.ContainsKey("cond_metric") ? data["cond_metric"].AsString() : "score",
            ["cond_counter"] = data.ContainsKey("cond_counter") ? data["cond_counter"].AsString() : "",
            ["cond_decider"] = data.ContainsKey("cond_decider") ? data["cond_decider"].AsString() : "game",
            ["default_path"] = data.ContainsKey("default_path") ? data["default_path"].AsInt32() : 0,
            // Auto-advance fallback for choice/sacrifice forks; -1 = pick randomly among affordable.
            ["timeout_path"] = data.ContainsKey("timeout_path") ? data["timeout_path"].AsInt32() : -1,
            // Optional audio accent (resolved path) + its loop flag + linear 0–1 volume.
            ["audio"] = data.ContainsKey("audio") ? data["audio"].AsString() : "",
            ["audio_loop"] = data.ContainsKey("audio_loop") && data["audio_loop"].AsBool(),
            ["audio_volume"] = data.ContainsKey("audio_volume") ? data["audio_volume"].AsSingle() : 1.0,
            // Carried through so GameLoop._current_map_key can key the fork's map marker.
            ["after_order"] = data.ContainsKey("after_order") ? data["after_order"].AsInt32() : 0,
            ["paths"] = paths,
        };
    }

    // Follows the current node's single out-edge (linear/round/shop/storyboard nodes).
    // Lands on "" (done) at an end. Fork nodes are advanced via ResolveFork, not here.
    public void Advance()
    {
        var edges = OutEdges(_currentId);
        _currentId = edges.Count > 0 ? edges[0].AsGodotDictionary()["to"].AsString() : "";
        EnterCurrent();
    }

    // Resolves a Loop End control node (GameLoop dispatches "loop_end" here): bump this loop's iteration count, then
    // evaluate its exit conditions under the combine mode. Exit → take the normal out-edge and reset the
    // count; keep looping → jump to `loop_to` (the body start). A missing loop_to exits (defensive; the
    // presave validator requires one). Loops always terminate on a linear body — the save-time validator
    // guarantees the body can satisfy a condition — so there's no runtime iteration cap.
    public void ResolveLoop()
    {
        var node = NodeOf(_currentId);
        var data = node.ContainsKey("data") ? node["data"].AsGodotDictionary() : new Dictionary();
        var loopId = _currentId;

        _loopCounts.TryGetValue(loopId, out int iters);
        iters += 1;
        _loopCounts[loopId] = iters;

        var loopTo = data.ContainsKey("loop_to") ? data["loop_to"].AsString() : "";
        if (loopTo != "" && _nodes.ContainsKey(loopTo) && !LoopExitReady(data, iters))
        {
            _currentId = loopTo;  // run the body again
        }
        else
        {
            _loopCounts.Remove(loopId);  // exiting — reset for any future re-entry
            var edges = OutEdges(loopId);
            _currentId = edges.Count > 0 ? edges[0].AsGodotDictionary()["to"].AsString() : "";
        }
        EnterCurrent();
    }

    // True when a loop's exit conditions are satisfied for iteration `iters`, under its combine mode
    // ("all" = AND, anything else = ANY/OR). No conditions ⇒ exit immediately (the validator flags that).
    private bool LoopExitReady(Dictionary data, int iters)
    {
        var conds = data.ContainsKey("loop_conditions") ? data["loop_conditions"].AsGodotArray() : new Array();
        if (conds.Count == 0)
            return true;
        bool all = data.ContainsKey("loop_combine") && data["loop_combine"].AsString() == "all";
        foreach (var cv in conds)
        {
            bool met = LoopConditionMet(cv.AsGodotDictionary(), iters);
            if (all && !met)
                return false;  // ALL: one unmet ⇒ not ready
            if (!all && met)
                return true;   // ANY: one met ⇒ ready
        }
        return all;  // ALL: every one met ⇒ true; ANY: none met ⇒ false
    }

    // Whether one loop exit condition is met now. counter ≥/≤ threshold · flag set · fixed repeats · has item.
    private bool LoopConditionMet(Dictionary c, int iters)
    {
        switch (c.ContainsKey("kind") ? c["kind"].AsString() : "")
        {
            case "counter":
                var counterVal = CounterValue(c.ContainsKey("counter") ? c["counter"].AsString() : "");
                var threshold = c.ContainsKey("threshold") ? c["threshold"].AsInt32() : 0;
                // cmp "lte" = count-down (exit when it drops to the value); default "gte" = climb to it.
                var cmp = c.ContainsKey("cmp") ? c["cmp"].AsString() : "gte";
                return cmp == "lte" ? counterVal <= threshold : counterVal >= threshold;
            case "flag":
                return HasFlag(c.ContainsKey("flag") ? c["flag"].AsString() : "");
            case "repeats":
                return iters >= (c.ContainsKey("count") ? c["count"].AsInt32() : 1);
            case "item":
                var inv = GetNodeOrNull<InventoryService>("/root/InventoryService");
                return inv != null && inv.OwnsItem(c.ContainsKey("item") ? c["item"].AsString() : "");
        }
        return false;
    }

    // Picks the fork's pathIndex-th out-edge and moves to its target. Out-of-range /
    // negative clamps to edge 0 (mirrors the old behaviour). No-op off a fork.
    public void ResolveFork(int pathIndex)
    {
        var node = NodeOf(_currentId);
        if (!(node.ContainsKey("type") && node["type"].AsString() == "fork"))
            return;

        var edges = OutEdges(_currentId);
        if (edges.Count == 0) { _currentId = ""; return; }
        if (pathIndex < 0 || pathIndex >= edges.Count)
            pathIndex = 0;

        var edge = edges[pathIndex].AsGodotDictionary();
        var data = node["data"].AsGodotDictionary();
        _playLog.Add(new Dictionary
        {
            ["type"] = "fork_choice",
            ["fork_title"] = data.ContainsKey("title") ? data["title"].AsString() : "",
            ["path_name"] = edge.ContainsKey("name") ? edge["name"].AsString() : "Path " + (pathIndex + 1),
            ["path_index"] = pathIndex,
            ["depth"] = node.ContainsKey("depth") ? node["depth"].AsInt32() : 0,
        });

        ApplyFlags(edge);        // the chosen choice's set_flags / clear_flags ("you chose X")
        ApplyCounters(edge);     // …its set_counters ("+1 notch for that choice")
        ApplyItemRemovals(edge); // …and any remove_items ("that path costs you the key")
        _currentId = edge.ContainsKey("to") ? edge["to"].AsString() : "";
        EnterCurrent();
    }

    // The journey is done once the current id is the "" sentinel (or points nowhere).
    public bool IsSequenceDone() => _currentId == "" || !_nodes.ContainsKey(_currentId);

    // True when no out-edge leads to another node — i.e. the current node is a terminal
    // item, so the run should route to the end screen instead of advancing. Trailing
    // shops/storyboards still count as "more items" and keep this false (preserves the
    // old "no real items after" semantics, not a rounds-only check).
    public bool IsLastRound() =>
        !OutEdges(_currentId).Any(e => e.AsGodotDictionary()["to"].AsString() != "");

    // Trajectory-relative total: rounds entered before the current node + the longest
    // round path forward from it (DAG longest path). The denominator shifts as the player
    // picks shorter/longer forks — and the bar jumps forward on a skip.
    public int TotalRounds()
    {
        int currentIsRound = TypeOf(_currentId) == "round" ? 1 : 0;
        return (_roundsEntered - currentIsRound) + LongestRoundPath(_currentId);
    }

    // All round nodes' data (every node, not traversal-filtered). Kept for API parity;
    // no current GDScript consumer.
    public Array GetPlayedRounds()
    {
        var result = new Array();
        foreach (var keyVariant in _nodes.Keys)
        {
            var n = _nodes[keyVariant.AsString()].AsGodotDictionary();
            if (n.ContainsKey("type") && n["type"].AsString() == "round")
                result.Add(n["data"]);
        }
        return result;
    }

    // Longest count of round nodes from `fromId` to any end (inclusive of fromId if it is
    // a round). DAG → the memoised DFS terminates; `seen` backstops a malformed cycle.
    private int LongestRoundPath(string fromId) =>
        LongestRoundPathRec(fromId, new System.Collections.Generic.Dictionary<string, int>(), new HashSet<string>());

    private int LongestRoundPathRec(string id, System.Collections.Generic.Dictionary<string, int> memo, HashSet<string> seen)
    {
        if (id == "" || !_nodes.ContainsKey(id) || seen.Contains(id)) 
            return 0;

        if (memo.TryGetValue(id, out int cached)) 
            return cached;

        seen.Add(id);
        int here = TypeOf(id) == "round" ? 1 : 0;
        int best = 0;

        foreach (var e in OutEdges(id))
            best = System.Math.Max(best, LongestRoundPathRec(e.AsGodotDictionary()["to"].AsString(), memo, seen));

        seen.Remove(id);

        int total = here + best;
        memo[id] = total;
        return total;
    }

    // Nodes reachable from `fromId` (inclusive). DAG; the accumulator also backstops a malformed cycle.
    private HashSet<string> Reachable(string fromId)
    {
        var acc = new HashSet<string>();
        ReachableRec(fromId, acc);
        return acc;
    }

    private void ReachableRec(string id, HashSet<string> acc)
    {
        if (id == "" || !_nodes.ContainsKey(id) || acc.Contains(id))
            return;
        acc.Add(id);
        foreach (var e in OutEdges(id))
            ReachableRec(e.AsGodotDictionary()["to"].AsString(), acc);
    }

    // Where a fork's branches rejoin: nodes reachable from two or more of `branchTargets`. The shared tail
    // past these belongs to no single choice, so the per-branch count stops here.
    private HashSet<string> ForkConvergence(System.Collections.Generic.List<string> branchTargets)
    {
        var count = new System.Collections.Generic.Dictionary<string, int>();
        foreach (var t in branchTargets)
            foreach (var n in Reachable(t))
                count[n] = count.TryGetValue(n, out int c) ? c + 1 : 1;
        var conv = new HashSet<string>();
        foreach (var kv in count)
            if (kv.Value >= 2)
                conv.Add(kv.Key);
        return conv;
    }

    // Longest count of round nodes from `fromId`, STOPPING at any convergence node (shared tail excluded).
    private int LongestRoundPathBounded(string fromId, HashSet<string> stopAt) =>
        LongestRoundPathBoundedRec(fromId, stopAt, new System.Collections.Generic.Dictionary<string, int>(), new HashSet<string>());

    private int LongestRoundPathBoundedRec(
        string id, HashSet<string> stopAt, System.Collections.Generic.Dictionary<string, int> memo, HashSet<string> seen)
    {
        if (id == "" || !_nodes.ContainsKey(id) || seen.Contains(id) || stopAt.Contains(id))
            return 0;
        if (memo.TryGetValue(id, out int cached))
            return cached;

        seen.Add(id);
        int here = TypeOf(id) == "round" ? 1 : 0;
        int best = 0;
        foreach (var e in OutEdges(id))
            best = System.Math.Max(best, LongestRoundPathBoundedRec(e.AsGodotDictionary()["to"].AsString(), stopAt, memo, seen));
        seen.Remove(id);

        int total = here + best;
        memo[id] = total;
        return total;
    }

    // ---------------------------------------------------------------------------
    // Save / Resume
    // ---------------------------------------------------------------------------

    // GameState's slice of the save record: the current node id + rounds-entered count
    // (so the resumed run restores its progress number). CoinService / ScoreService /
    // GameLoop add their own portions.
    public Dictionary CaptureSaveData() => new Dictionary
    {
        ["current_node"] = _currentId,
        ["rounds_entered"] = _roundsEntered,
        ["flags"] = FlagsArray(),
        ["counters"] = CountersDict(),
        ["loop_iters"] = LoopCountsDict(),
        ["discovered"] = DiscoveredNodes(),
        ["played_pool_clips"] = PlayedPoolClipsArray(),
    };

    // Per-loop iteration counts {loop_node_id: int} for the save record, so a resume mid-loop keeps count.
    private Dictionary LoopCountsDict()
    {
        var d = new Dictionary();
        foreach (var kv in _loopCounts)
            d[kv.Key] = kv.Value;
        return d;
    }

    // The drawn no-repeat pool clips as a Godot Array (for the save record).
    private Array PlayedPoolClipsArray()
    {
        var a = new Array();
        foreach (var p in _playedPoolClips)
            a.Add(p);
        return a;
    }

    // The run's counters as a Godot Dictionary {name: int} — for the save record and the HUD.
    public Dictionary CountersDict()
    {
        var d = new Dictionary();
        foreach (var kv in _counters)
            d[kv.Key] = kv.Value;
        return d;
    }

    // The run's discovered node ids as a Godot Array — the save record above and GameLoop's map fog both
    // read it. Empty until the player has landed on at least the start node.
    public Array DiscoveredNodes()
    {
        var a = new Array();
        foreach (var d in _discovered) 
            a.Add(d);

        return a;
    }

    // The run's flags as a Godot Array (for the save record).
    private Array FlagsArray()
    {
        var a = new Array();
        foreach (var f in _flags) 
            a.Add(f);

        return a;
    }

    // Restores position from a save record. New saves carry current_node; a pre-graph
    // save (sequence_index, no current_node) or a node that no longer exists (journey
    // edited) falls back to the journey start — saves are single-use and short-lived, so
    // losing position across the format change is acceptable.
    public void LoadFromSave(Dictionary journeyData, Dictionary saveData)
    {
        Journey = journeyData;
        _nodes = journeyData.ContainsKey("nodes") ? journeyData["nodes"].AsGodotDictionary() : new Dictionary();
        _playLog.Clear();
        _flags.Clear();
        _counters.Clear();
        _loopCounts.Clear();
        _discovered.Clear();
        _playedPoolClips.Clear();

        if (saveData.ContainsKey("current_node") && _nodes.ContainsKey(saveData["current_node"].AsString()))
        {
            _currentId = saveData["current_node"].AsString();
            _roundsEntered = saveData.ContainsKey("rounds_entered") ? saveData["rounds_entered"].AsInt32() : 0;
            // Restore the flags accumulated up to the save point (don't re-walk the journey).
            if (saveData.ContainsKey("flags"))
                foreach (var flag in saveData["flags"].AsGodotArray())
                {
                    var name = flag.AsString();
                    if (name != "") _flags.Add(name);
                }
            // Restore the counters accumulated up to the save point (same rationale as flags).
            if (saveData.ContainsKey("counters"))
            {
                var saved = saveData["counters"].AsGodotDictionary();
                foreach (var key in saved.Keys)
                {
                    var name = key.AsString();
                    if (name != "") _counters[name] = saved[key].AsInt32();
                }
            }
            // Restore per-loop iteration counts so a resume mid-loop continues from the right pass.
            if (saveData.ContainsKey("loop_iters"))
            {
                var savedLoops = saveData["loop_iters"].AsGodotDictionary();
                foreach (var key in savedLoops.Keys)
                {
                    var lid = key.AsString();
                    if (lid != "") _loopCounts[lid] = savedLoops[key].AsInt32();
                }
            }
            // Restore the fog-of-war discovery set the same way (per-run, but persists across resume).
            if (saveData.ContainsKey("discovered"))
                foreach (var d in saveData["discovered"].AsGodotArray())
                {
                    var did = d.AsString();
                    if (did != "") _discovered.Add(did);
                }
            // Restore the no-repeat pool clips already drawn, so a pool after a checkpoint still skips them.
            if (saveData.ContainsKey("played_pool_clips"))
                foreach (var p in saveData["played_pool_clips"].AsGodotArray())
                {
                    var vp = p.AsString();
                    if (vp != "") _playedPoolClips.Add(vp);
                }
        }
        else
        {
            _currentId = journeyData.ContainsKey("start") ? journeyData["start"].AsString() : "";
            _roundsEntered = 0;
            EnterCurrent();
        }
    }

    // Called by GameLoop after each round ends (before ScoreService.EndRound).
    // roundName / lengthMs are passed explicitly from GDScript to avoid C# key-lookup
    // mismatches on the Variant dict.
    public void LogRound(Dictionary roundData, string roundName, int lengthMs, bool skipped = false)
    {
        var node = NodeOf(_currentId);
        _playLog.Add(new Dictionary
        {
            ["type"] = "round",
            ["name"] = roundName,
            ["length_ms"] = lengthMs,
            ["data"] = roundData,
            ["depth"] = node.ContainsKey("depth") ? node["depth"].AsInt32() : 0,
            // A skipped round still occupies its place in the run — the end screen marks it
            // rather than hiding it, so the route stays honest about what was played.
            ["skipped"] = skipped,
        });
    }

    // Full chronological log of fork choices and rounds played (for the end screen).
    public Array GetPlayLog()
    {
        var result = new Array();

        foreach (var entry in _playLog)
            result.Add(entry);

        return result;
    }
}
