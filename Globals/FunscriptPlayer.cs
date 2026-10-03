using Godot;
using Godot.Collections;
using System;
using System.Collections.Generic;

public partial class FunscriptPlayer : Node
{
    private struct Action { public float AtMs; public int Pos; }

    // Per-axis state for secondary T-code channels (L1, L2, R0, R1, R2).
    // Serial-only — Buttplug ignores these entirely.
    private class AxisState
    {
        public List<Action> Actions = new List<Action>();
        // Keyframe cursor for the per-keyframe restim fan-out in _Process.
        public int Index = 0;
        // Bracket cursor for the serial stream in _PhysicsProcess: the segment containing "now". Moves
        // both ways, so a seek recovers on its own.
        public int InterpIndex = 0;
    }

    // Per-channel vibrator script state.
    // Channel 0 = vib1 (primary motor), channel 1 = vib2 (secondary motor).
    // Buttplug-only — serial devices ignore these.
    private class VibState
    {
        public List<Action> Actions = new List<Action>();
        public int Index = 0;
    }

    // Activity-driven constrict (pneumatic squeeze) state machine. Pure logic — fed stroke activity
    // (funscript units/sec) + script progress, outputs a discrete level (0/1/2) with sustain + min-hold
    // hysteresis so it engages/releases smoothly instead of chattering. Config seeded in ResolveOutput.
    private sealed class ConstrictController
    {
        public int MaxLevel = 1;
        public double L1Threshold = 45.0, L1SustainMs = 5000.0;
        public double ReleaseThreshold = 25.0, ReleaseSustainMs = 10000.0;
        public double MinHoldMs = 12000.0;
        public bool L2Enabled = false;
        public double L2Threshold = 90.0, L2SustainMs = 8000.0, L2FinalPct = 12.0;
        public bool HoldOnPause = true;

        public int Level { get; private set; }
        private double _aboveL1Ms, _belowReleaseMs, _aboveL2Ms, _heldMs;

        public void Reset()
        {
            Level = 0;
            _aboveL1Ms = _belowReleaseMs = _aboveL2Ms = _heldMs = 0.0;
        }

        // Advance by dtMs with the current stroke activity (units/sec) and script progress (0–100).
        public void Update(double dtMs, double activity, double progressPct, bool playing)
        {
            if (!playing)
            {
                if (!HoldOnPause)
                    Reset();
                return; // held (frozen) while paused when HoldOnPause
            }

            if (Level == 0)
            {
                if (activity >= L1Threshold)
                {
                    _aboveL1Ms += dtMs;
                    if (_aboveL1Ms >= L1SustainMs)
                    {
                        Level = 1;
                        _heldMs = 0.0;
                        _belowReleaseMs = 0.0;
                        _aboveL2Ms = 0.0;
                    }
                }
                else
                {
                    _aboveL1Ms = 0.0;
                }
                return;
            }

            // Engaged (level >= 1).
            _heldMs += dtMs;

            // Level-2 promotion — enabled, allowed, and only in the final stretch of the script.
            if (Level == 1 && L2Enabled && MaxLevel >= 2)
            {
                if (activity >= L2Threshold && progressPct >= (100.0 - L2FinalPct))
                {
                    _aboveL2Ms += dtMs;
                    if (_aboveL2Ms >= L2SustainMs)
                        Level = 2;
                }
                else
                {
                    _aboveL2Ms = 0.0;
                }
            }

            // Release — sustained low activity AND the minimum hold has elapsed.
            if (activity < ReleaseThreshold)
            {
                _belowReleaseMs += dtMs;
                if (_belowReleaseMs >= ReleaseSustainMs && _heldMs >= MinHoldMs)
                    Reset();
            }
            else
            {
                _belowReleaseMs = 0.0;
            }
        }
    }

    // Maps T-code axis name → its loaded script state.
    // Explicitly System.Collections.Generic — AxisState is a C# class, not a Godot Variant.
    private readonly System.Collections.Generic.Dictionary<string, AxisState> _axes =
        new System.Collections.Generic.Dictionary<string, AxisState>();

    // Maps vibrator channel index → its loaded script state.
    private readonly System.Collections.Generic.Dictionary<int, VibState> _vibScripts =
        new System.Collections.Generic.Dictionary<int, VibState>();

    // Maps a restim (E-Stim Full) T-code axis name → a funscript that drives it directly.
    // Populated from a round's estim_scripts (alpha/beta/volume/carrier_frequency/…). restim-only:
    // a script here supersedes both the motion→restim mapping and the manual slider for that axis.
    private readonly System.Collections.Generic.Dictionary<string, AxisState> _restimScripts =
        new System.Collections.Generic.Dictionary<string, AxisState>();

    private static readonly string[] KnownAxes = { "L1", "L2", "R0", "R1", "R2" };

    private enum StrokeBackend { None, Serial, Buttplug }

    private List<Action> _actions = new List<Action>();

    // "V motion" beats — local minima in the L0 track — for the optional beat-bar
    // visualiser. Each entry is (AtMs, depth) where depth is the 0–100 dip size.
    private readonly List<Vector2> _beats = new List<Vector2>();

    private bool _playing = false;
    private double _positionMs = 0.0;
    private int _actionIndex = 0;
    // Resolved routing plan (rebuilt by BuildRoutingPlan): the stroke has one target; vibe actuators
    // fan out per their source (vibe1 / vibe2 / stroke); constrict actuators run the auto state machine.
    private StrokeBackend _strokeBackend = StrokeBackend.None;
    private int _strokeDeviceIndex = -1;   // Buttplug linear device index when _strokeBackend == Buttplug
    private readonly List<(int Index, int Channel, string Source)> _vibeRoutes = new List<(int Index, int Channel, string Source)>();
    private readonly List<(int Index, int Channel)> _constrictRoutes = new List<(int Index, int Channel)>();
    // Smooth output clock. The video reports its position a whole frame at a time (~33ms at 30fps)
    // and micro-jitters; forwarding stroke commands on that raw clock is what jerks the OSR. So our
    // clock free-runs on real time (advanced in _Process) and SyncTo only NUDGES it toward the
    // video — snapping only on a large gap (a seek). Output stays smooth while locked to the media.
    private bool _clockPrimed = false;
    private const double ClockResyncThresholdMs = 75.0; // gap this large = a seek → snap, don't slew
    private const double ClockReconcileGain = 0.15;     // fraction of the video-clock error closed per sync

    // Serial stroke interpolation. A bracket cursor into _actions for the current time, plus the last
    // target sent (for the max-speed slew clamp). The serial stroke position is STREAMED at a steady
    // high rate by _PhysicsProcess — not forwarded per keyframe — which is what makes an OSR/SR6
    // glide the way MultiFunPlayer does. Buttplug stays on the per-keyframe path (BLE rate limits).
    private int _interpIndex = 0;
    private double _lastSerialTarget = 50.0;

    // ── Auto Twist ──────────────────────────────────────────────────────────
    // R0 synthesised from the stroke for content with no twist script (MULTIAXIS_DESIGN.md §1). Not an
    // entry in _axes: it is derived per tick from the L0 actually sent, so it never goes through the
    // keyframe loop, is never fanned out to restim, and never counts as an authored R0.

    // Gain on the stroke; 0 = off. Seeded in ResolveOutput, pushed live by Options via SetAutoTwist.
    private double _autoTwistGain = 0.0;
    // The last twist sent, which the per-tick speed ceiling measures from. Centre when idle.
    private double _lastAutoTwist = 50.0;
    // Whether Auto Twist has moved R0 since it was last homed, so a pause only re-centres a twist
    // this code actually moved.
    private bool _autoTwistDriving = false;
    // The loaded main track is an e-stim ALPHA channel rather than a stroke: nothing to twist with.
    private bool _mainIsAlpha = false;

    // ── Serial axis stream ──────────────────────────────────────────────────
    // Every serial axis — stroke, authored secondary axes, Auto Twist — is sampled once per physics tick
    // and sent as ONE T-code line (MULTIAXIS_DESIGN.md §7 step 2). One per-tick path is what lets the
    // multi-axis modifiers act the moment they start, instead of at an axis's next keyframe, which on a
    // slow pitch or roll script can be seconds away.

    // This tick's batch, index-aligned. Reused every tick rather than allocated.
    private readonly List<string> _tickAxes = new List<string>();
    private readonly List<double> _tickPositions = new List<double>();
    // Last position streamed per secondary axis, in T-code steps (0–9999). An axis that hasn't moved
    // since is left out of the line — a held pitch costs nothing. Forgotten whenever something outside
    // the stream moves the axes (a park, a home, an override swap), and every AxisResendTicks anyway, so
    // a device that lost a command or reconnected is back in step within half a second.
    private readonly System.Collections.Generic.Dictionary<string, int> _lastSentAxisSteps =
        new System.Collections.Generic.Dictionary<string, int>();
    private int _ticksSinceAxisResend = 0;
    private const int AxisResendTicks = 60;

    // How fast synthesised twist may move, in units/sec. Only engages on fast, deep strokes at the upper
    // steps — a 150 ms full-depth stroke at Strong would otherwise ask for ~670 u/s, which is a shake.
    // The one number here that can only be tuned on hardware.
    private const double MaxTwistSpeed = 500.0;
    // Interval multiple the serial stream sends with (slightly > tick so the OSR keeps gliding toward
    // a fresh target). Best value varies by device/firmware, so it's a live setting — seeded in
    // ResolveOutput, overridable via SetSerialInterpFactor (Options).
    private double _serialInterpFactor = 1.6;

    // Constrict auto state machine — driven by smoothed stroke activity (units/sec), updated on a throttle.
    private readonly ConstrictController _constrict = new ConstrictController();
    private double _strokeActivity = 0.0;
    private double _constrictTickMs = 0.0;
    private int _lastConstrictLevel = -1;
    private const double ConstrictTickIntervalMs = 200.0;
    private const double ActivityDecayHalfLifeMs = 2000.0;
    private bool _outputResolved = false;
    private int _rangeMin = 0;
    private int _rangeMax = 100;

    // Per-axis range window for the secondary positional axes (L1/L2/R0/R1/R2),
    // independent of the stroke axis [_rangeMin,_rangeMax]. Seeded in ResolveOutput,
    // updated live by SetAxisRangeClamp. A missing axis falls back to full 0–100.
    private readonly System.Collections.Generic.Dictionary<string, (int Min, int Max)> _axisRanges =
        new System.Collections.Generic.Dictionary<string, (int Min, int Max)>();

    // Storyboard filler — alternating stroke played while a storyboard screen is
    // open so the device doesn't sit idle. Independent of _playing / the funscript.
    private bool _fillerActive = false;
    private double _fillerElapsedMs = 0.0;
    private int _fillerHalfCycleMs = 2000; // ms per half-stroke (hi→lo or lo→hi)
    private int _fillerLo = 0;
    private int _fillerHi = 100;
    private bool _fillerGoingToLo = false; // false = first command goes to hi
    private double _fillerVibTickMs = 0.0;
    private const double FillerVibTickIntervalMs = 50.0;

    // Ease-in state — blends output from neutral (50) toward the script position
    // at the start of each round, journey, or resume-from-pause.
    private bool _easing = false;
    private double _easeStartMs = 0.0;
    private double _easeDurationMs = 0.0;
    private float _easeFromPos = 50f; // the ease blends FROM here (the device's current pos), not home
    private const float EaseSpeedUnitsPerMs = 40f / 1000f; // 40 units/sec
    private const double EaseMinMs = 50.0;
    private const double EaseMaxMs = 1500.0;

    // Mirror-ease state — the "mirror" shop item flips position to 100-pos.
    // Toggling it on/off is eased through the centre rather than snapped: an
    // instant reversal into the opposite direction is jarring and unsafe on a
    // linear device. _mirrorBlend lerps 0↔1; at 0.5 every position maps to 50,
    // so the device passes through neutral instead of jumping extreme-to-extreme.
    private float _mirrorBlend = 0f;
    private double _mirrorClockMs = double.NaN; // last clock the blend advanced from
    private const double MirrorEaseMs = 700.0;

    // The same ease for the multi-axis reverse (Contrary), kept apart from the stroke's so the two curses
    // can come and go independently.
    private float _axisMirrorBlend = 0f;
    private double _axisMirrorClockMs = double.NaN;

    // The turning axes, which axis modifiers drive with their stronger `rotary_` values.
    private static readonly string[] RotaryAxes = { "R0", "R1", "R2" };

    public bool Playing => _playing;
    public int ActionCount => _actions.Count;

    /// Current playback clock in milliseconds — used by the beat-bar HUD so it
    /// stays in sync with the device whether video-driven or free-running.
    /// A positive delay pushes the device (and this reported position) LATER.
    public double PositionMs => _positionMs - StrokeDelay();

    // Cached autoload references — resolved once instead of looked up per-call
    // (some were hit every frame, per axis, inside _Process). FunscriptPlayer is
    // a late autoload, so all of these exist by the time _Ready runs.
    private SerialDeviceService _serial;
    private ButtplugService _buttplug;
    private RestimService _restim;
    private InventoryService _inventory;
    private ScoreService _score;
    private Node _settings;

    // The pure route resolver (GDScript static, unit-tested). Loaded once; called with the settings
    // config + the live Buttplug catalog to produce the dispatch plan.
    private GDScript _deviceRoutingScript;

    public override void _Ready()
    {
        _serial = GetNode<SerialDeviceService>("/root/SerialDeviceService");
        _buttplug = GetNode<ButtplugService>("/root/ButtplugService");
        _restim = GetNode<RestimService>("/root/RestimService");
        _inventory = GetNode<InventoryService>("/root/InventoryService");
        _score = GetNode<ScoreService>("/root/ScoreService");
        _settings = GetNode("/root/SettingsService");
        _deviceRoutingScript = GD.Load<GDScript>("res://scripts/device/DeviceRouting.gd");
        _LoadRestimManual();

        // Stream serial stroke output at a steady high rate (see _PhysicsProcess), decoupled from
        // render FPS and the video frame clock. Nothing else in the project uses the physics loop,
        // so raising this only affects our stroke tick.
        Engine.PhysicsTicksPerSecond = 120;
    }

    // ── restim (e-stim) manual axis values ──────────────────────────────────────
    // Manual value (percent 0–100) per "E-Stim Full" axis. Motion axes use this only as a
    // fallback when the current round has no matching funscript; the rest always use it.
    private readonly System.Collections.Generic.Dictionary<string, int> _restimManual =
        new System.Collections.Generic.Dictionary<string, int>();

    private void _LoadRestimManual()
    {
        foreach (var axis in RestimService.AllAxes)
            _restimManual[axis] = _settings.Call("get_restim_axis", axis).AsInt32();
    }

    // True when the round provides a funscript that drives this restim axis live — either a
    // dedicated estim script (alpha/beta/carrier_frequency/…) or, for the six motion axes, the
    // corresponding motion funscript. Used to skip the manual slider for scripted axes.
    private bool RestimAxisHasScript(string restimAxis)
    {
        if (_restimScripts.ContainsKey(restimAxis))
            return true;
        switch (restimAxis)
        {
            case "L0": return _actions.Count > 0;   // main stroke
            case "L1": return _axes.ContainsKey("L1");  // surge
            case "C0": return _axes.ContainsKey("R0");  // twist
            case "P0": return _axes.ContainsKey("R2");  // pitch
            case "V1": return _axes.ContainsKey("L2");  // sway
            case "V2": return _axes.ContainsKey("R1");  // roll
            default: return false;
        }
    }

    /// Live update of one restim manual axis value (Options slider), percent 0–100.
    /// Pushes immediately so a connected restim session responds without a round restart.
    public void SetRestimAxisValue(string axis, int percent)
    {
        percent = Math.Clamp(percent, 0, 100);
        _restimManual[axis] = percent;
        var restim = _restim;
        if (restim != null && restim.RestimConnected)
            restim.SendTCode(axis, percent / 100.0);
    }

    /// Send every manual axis value to restim in one frame: all manual-only axes, plus any
    /// motion axis the current round doesn't script. Called on connect and on Play/Resume.
    public void SendRestimManualState()
    {
        var restim = _restim;
        if (restim == null || !restim.RestimConnected)
            return;

        var cmds = new System.Collections.Generic.List<(string, double, uint)>();
        foreach (var axis in RestimService.AllAxes)
        {
            if (RestimAxisHasScript(axis))
                continue;
            int percent = _restimManual.TryGetValue(axis, out int p) ? p : 0;
            cmds.Add((axis, Math.Clamp(percent, 0, 100) / 100.0, 0u));
        }
        restim.SendBatch(cmds);
    }

    /// Push updated range-clamp values directly into the player.
    /// Called by the Options screen on every slider change so mid-playback
    /// adjustments take effect on the very next command without needing
    /// a round restart.
    public void SetRangeClamp(int min, int max)
    {
        _rangeMin = min;
        _rangeMax = max;
    }

    /// Live per-axis range update for one secondary positional axis (Options slider),
    /// mirroring SetRangeClamp for the stroke axis. `axis` is a T-code name (L1/R0/…).
    public void SetAxisRangeClamp(string axis, int min, int max) => _axisRanges[axis] = (min, max);

    // Current range window for a secondary axis; full 0–100 (no limiting) until seeded.
    private (int Min, int Max) GetAxisRange(string axis) =>
        _axisRanges.TryGetValue(axis, out var r) ? r : (0, 100);

    public void LoadFunscript(string path)
    {
        // GameLoop swaps a sibling .alpha file in for the main track when one exists; that is e-stim
        // position, not a stroke, so Auto Twist has nothing to follow.
        string stem = System.IO.Path.GetFileNameWithoutExtension(path ?? "").ToLowerInvariant();
        _mainIsAlpha = stem.EndsWith(".alpha") || stem.EndsWith("_alpha");
        _lastAutoTwist = 50.0;
        _actions.Clear();
        _actionIndex = 0;
        _positionMs = 0.0;
        _clockPrimed = false;
        _interpIndex = 0;
        _lastSerialTarget = _homePosition;
        _playing = false;
        // Fully invalidate the resolve cache — a new round must rebuild the routing plan.
        // _outputResolved = false forces Play()/Resume() to re-run BuildRoutingPlan even if Options
        // was opened between rounds (Pause → EaseToNeutral → ResolveOutput would otherwise leave it true).
        _strokeBackend = StrokeBackend.None;
        _strokeDeviceIndex = -1;
        _vibeRoutes.Clear();
        _outputResolved = false;

        // A new round starts clean — drop any override still mid-play (a cut at the round boundary).
        _overrideActive = false;
        _overrideImmune = false;
        _savedActions = null;
        _savedAxes = null;
        _savedVibs = null;
        _savedRestim = null;

        foreach (var kv in _axes)
        {
            kv.Value.Index = 0;
            kv.Value.InterpIndex = 0;
        }
        foreach (var kv in _vibScripts)
            kv.Value.Index = 0;
        foreach (var kv in _restimScripts)
            kv.Value.Index = 0;
        ForgetSentAxes();

        string absPath = ProjectSettings.GlobalizePath(path);
        using var funscriptFile = FileAccess.Open(absPath, FileAccess.ModeFlags.Read);
        if (funscriptFile == null)
        {
            GD.PrintErr($"FunscriptPlayer: cannot open {path}");
            return;
        }

        var parser = new Json();
        if (parser.Parse(funscriptFile.GetAsText()) != Error.Ok)
        {
            GD.PrintErr($"FunscriptPlayer: JSON parse error in {path}");
            return;
        }

        var funscript = parser.Data.AsGodotDictionary();
        var rawActions = funscript.ContainsKey("actions") ? funscript["actions"].AsGodotArray() : new Godot.Collections.Array();
        foreach (var rawAction in rawActions)
        {
            var action = rawAction.AsGodotDictionary();
            _actions.Add(new Action
            {
                AtMs = action.ContainsKey("at") ? action["at"].AsSingle() : 0f,
                Pos = action.ContainsKey("pos") ? action["pos"].AsInt32() : 0,
            });
        }

        _ExtractBeats();
    }

    // Finds every "V motion" — a local minimum where the track dips and rises
    // again — and records its timestamp and dip depth for the beat-bar HUD.
    private void _ExtractBeats()
    {
        _beats.Clear();
        for (int i = 1; i < _actions.Count - 1; i++)
        {
            int prev = _actions[i - 1].Pos;
            int cur = _actions[i].Pos;
            int next = _actions[i + 1].Pos;
            if (prev > cur && cur < next)
            {
                float depth = Math.Min(prev, next) - cur;
                _beats.Add(new Vector2(_actions[i].AtMs, depth));
            }
        }
    }

    /// Returns the V-motion beats as Vector2(timeMs, depth 0-100) for the beat bar.
    public Godot.Collections.Array GetBeats()
    {
        var arr = new Godot.Collections.Array();
        foreach (var b in _beats)
            arr.Add(b);
        return arr;
    }

    // Home-position config — updated live by Options via SetHomePosition().
    // L0 only: secondary axes always home to 0.5 regardless of this setting.
    private int _homePosition = 50;   // 0–100, matches funscript scale
    private uint _homeEaseMs = 2000;  // milliseconds for the home ease move

    // Fixed duration used only when parking unloaded secondary axes at round start.
    private const uint AxisParkMs = 500;

    /// Push updated home-position config directly into the player so mid-session
    /// changes in Options take effect without a restart.
    public void SetHomePosition(int position, int easeMs)
    {
        _homePosition = Math.Clamp(position, 0, 100);
        _homeEaseMs = (uint)Math.Max(50, easeMs);
    }

    // Per-backend latency compensation — shifts each output stream's sample time relative to the
    // playback clock to offset device / Bluetooth / serial lag. Positive = that backend acts earlier.
    // Applied per stream in _Process (stroke uses its backend's delay; vibe = intiface; axes = serial).
    private int _serialDelayMs = 0;
    private int _intifaceDelayMs = 0;

    // Vibrator output scale (0–1). Applied to every vibration command so the
    // user can dial overall strength down. No effect on linear devices.
    private float _vibeIntensity = 1.0f;

    // Max stroke speed for linear (L0) output, in funscript units/sec.
    // 0 = unlimited. Moves faster than the cap are slowed by stretching duration.
    private int _maxStrokeSpeed = 0;

    /// Live-update both per-backend delays together (the legacy single Options slider). Slice 4's UI
    /// and the in-play hotkeys use the per-backend setters below.
    public void SetLatencyOffset(int offsetMs)
    {
        _serialDelayMs = offsetMs;
        _intifaceDelayMs = offsetMs;
    }

    /// Live-update the serial (T-code) output delay, in milliseconds.
    public void SetSerialDelay(int ms) => _serialDelayMs = ms;

    /// Live-update the Intiface (Buttplug) output delay, in milliseconds.
    public void SetIntifaceDelay(int ms) => _intifaceDelayMs = ms;

    // Delay for whichever backend currently drives the stroke (serial or Buttplug), 0 if none. Also
    // offsets PositionMs so the beat-bar HUD stays aligned with the stroker.
    private double StrokeDelay() =>
        _strokeBackend == StrokeBackend.Serial ? _serialDelayMs
        : (_strokeBackend == StrokeBackend.Buttplug ? _intifaceDelayMs : 0.0);

    /// Live-update the vibrator intensity scale from Options (percent 0–100).
    public void SetVibeIntensity(int percent) => _vibeIntensity = Math.Clamp(percent, 0, 100) / 100f;

    /// Live-update the max stroke speed cap from Options (units/sec, 0 = off).
    public void SetMaxStrokeSpeed(int unitsPerSec) => _maxStrokeSpeed = Math.Max(0, unitsPerSec);

    /// Live Auto Twist gain from Options (0 = off, 1 = full travel at a full stroke). The steps and their
    /// gains live in SettingsService, so this only ever receives a number.
    public void SetAutoTwist(double gain) => _autoTwistGain = Math.Clamp(gain, 0.0, 1.0);

    /// The whole Auto Twist model, and nothing else: twist = centre + gain × (stroke − centre), then held
    /// to at most `maxDelta` from the previous twist. Pure — public only so the gdUnit suite can reach it
    /// the way it reaches GameState.
    ///
    /// Stateless by design. Each tick's twist depends only on that tick's stroke, so a tick the ceiling
    /// trims simply lags and the next one catches up; nothing accumulates, so it cannot drift off centre.
    /// Works in full 0–100 space — the player's R0 window is applied once, by the caller.
    public double AutoTwistStep(double stroke, double previousTwist, double gain, double maxDelta)
    {
        double twist = 50.0 + gain * (stroke - 50.0);
        if (maxDelta > 0.0)
            twist = Math.Clamp(twist, previousTwist - maxDelta, previousTwist + maxDelta);
        return Math.Clamp(twist, 0.0, 100.0);
    }

    /// The sent stroke with the player's Stroke Range taken back out, as a 0–100 script position. Pure,
    /// public for the same reason as AutoTwistStep.
    ///
    /// That range fits the STROKE to the player's device. The twist has a window of its own (R0), and
    /// scaling it by both would compress it twice: a 10–90 stroke range would cap Strong at 10–90 before
    /// R0's window even applied, so full twist travel was out of reach for anyone who had narrowed their
    /// stroke. Every effect, the ease and the max-speed cap survive the round trip — they happen before
    /// or on top of the rescale, and the rescale is linear, so undoing it leaves them in place.
    public double StrokeInScriptSpace(double sent, int rangeMin, int rangeMax)
    {
        double span = rangeMax - rangeMin;
        if (span <= 0.0)
            return 50.0;  // a zero-width stroke range carries no stroke to follow
        return Math.Clamp((sent - rangeMin) / span * 100.0, 0.0, 100.0);
    }

    // On, with a stroke to follow, and no authored twist playing. Checked against what actually LOADED:
    // _axes holds the round's merged axis set (sibling files included), or an override's own channels
    // while one plays — so an override with R0 wins and one without leaves Auto Twist running on its
    // stroke. A failed R0 load leaves no track, and therefore no suppression.
    private bool AutoTwistActive() =>
        _autoTwistGain > 0.0
        && !_mainIsAlpha
        && !(_axes.TryGetValue("R0", out var authored) && authored.Actions.Count > 0);

    // One tick of Auto Twist, on the same line as the stroke move it was derived from. Serial only:
    // restim maps R0 to its carrier frequency, which a synthesised twist must never touch.
    private void QueueAutoTwist(double stroke, double delta, Godot.Collections.Array effects)
    {
        _lastAutoTwist = AutoTwistStep(stroke, _lastAutoTwist, _autoTwistGain, MaxTwistSpeed * delta);
        (int axisMin, int axisMax) = GetAxisRange("R0");
        // Axis modifiers reshape what is SENT, not the follow itself — so the speed ceiling keeps
        // measuring the honest twist, and a curse lifting doesn't leave it anywhere it has to catch up from.
        double twist = AxisModifiedPos("R0", _lastAutoTwist, effects, _axisMirrorBlend);
        QueueMove("R0", SecondaryAxisOutput(twist, axisMin, axisMax, 1.0));
        _autoTwistDriving = true;
    }

    /// A secondary axis's script position (0–100) as sent: rescaled into the player's window for that
    /// axis, blended in from centre by `easeBlend` (0 = centre, 1 = fully the script), then held inside
    /// the window. Pure — public for the gdUnit suite, like AutoTwistStep.
    ///
    /// The order is the one the per-keyframe path always used, so a script plays exactly as before: the
    /// window first (a symmetric window narrows the swing around centre), the ease from centre because
    /// secondary axes home to centre, and the clamp last as a safety net — it is what keeps an ease from
    /// 50 inside a window that excludes 50.
    public double SecondaryAxisOutput(double scriptPos, int axisMin, int axisMax, double easeBlend)
    {
        double pos = axisMin + (axisMax - axisMin) * Math.Clamp(scriptPos, 0.0, 100.0) / 100.0;
        if (easeBlend < 1.0)
            pos = 50.0 + (pos - 50.0) * easeBlend;
        return Math.Clamp(pos, axisMin, axisMax);
    }

    /// Where a script is at `nowMs`, interpolated between its keyframes; the first position before it
    /// starts, the last after it ends. `points` is Array[Vector2(at_ms, pos)]. Test seam for SampleActions.
    public double SampleScriptAt(Godot.Collections.Array points, double nowMs)
    {
        int cursor = 0;
        return SampleActions(ActionsFromPoints(points), ref cursor, nowMs);
    }

    // The straight line between the two keyframes around `now` — the path the firmware would tween along
    // anyway, sampled every tick. `cursor` is the bracket index, carried between calls so each tick only
    // steps from where the last one was; it walks back as well as forward, so seeks recover.
    private static double SampleActions(List<Action> actions, ref int cursor, double now)
    {
        cursor = Math.Clamp(cursor, 0, Math.Max(0, actions.Count - 1));
        while (cursor + 1 < actions.Count && actions[cursor + 1].AtMs <= now)
            cursor++;
        while (cursor > 0 && actions[cursor].AtMs > now)
            cursor--;

        if (now <= actions[0].AtMs)
            return actions[0].Pos;
        if (cursor + 1 >= actions.Count)
            return actions[actions.Count - 1].Pos;

        double a = actions[cursor].AtMs;
        double b = actions[cursor + 1].AtMs;
        double frac = b > a ? Math.Clamp((now - a) / (b - a), 0.0, 1.0) : 0.0;
        return actions[cursor].Pos + (actions[cursor + 1].Pos - actions[cursor].Pos) * frac;
    }

    // Adds one axis to this tick's line. `pos` is 0–100.
    private void QueueMove(string axis, double pos)
    {
        _tickAxes.Add(axis);
        _tickPositions.Add(pos / 100.0);
    }

    // Something outside the stream just moved the secondary axes, so the next tick must send every one
    // of them again rather than trusting what it last sent.
    private void ForgetSentAxes() => _lastSentAxisSteps.Clear();

    // How far the round-start ease has got, as a smoothstep 0–1 (1 when not easing). The stroke and the
    // secondary axes share it, so every axis blends in from neutral together.
    private float EaseBlend()
    {
        if (!_easing)
            return 1f;
        double elapsed = _positionMs - _easeStartMs;
        float t = (float)Math.Clamp(elapsed / _easeDurationMs, 0.0, 1.0);
        return t * t * (3f - 2f * t);
    }

    /// Live-update the serial stroke-smoothing interval factor from Options. Clamped to the same
    /// band as the setting so a slider (or a hand-edited config) can't drive it out of range.
    public void SetSerialInterpFactor(double factor) => _serialInterpFactor = Math.Clamp(factor, 1.0, 4.0);

    // Stretches a linear move's duration when it would exceed the configured
    // max stroke speed, so aggressive scripts are gently slowed instead of
    // snapping. _maxStrokeSpeed of 0 disables the cap.
    private uint _CapDuration(int fromPos, int toPos, uint durationMs)
    {
        if (_maxStrokeSpeed <= 0)
            return durationMs;

        int distance = Math.Abs(toPos - fromPos);

        if (distance == 0)
            return durationMs;
        uint minMs = (uint)Math.Ceiling(distance * 1000.0 / _maxStrokeSpeed);

        return Math.Max(durationMs, minMs);
    }

    // Load a secondary-axis funscript. Call before Play().
    // axis: T-code name, e.g. "L1", "R0".
    public void LoadAxisScript(string axis, string path)
    {
        var state = new AxisState();
        string absPath = ProjectSettings.GlobalizePath(path);

        using var funscriptFile = FileAccess.Open(absPath, FileAccess.ModeFlags.Read);
        if (funscriptFile == null)
        {
            GD.PrintErr($"FunscriptPlayer: cannot open axis script {path}");
            return;
        }

        var parser = new Json();
        if (parser.Parse(funscriptFile.GetAsText()) != Error.Ok)
        {
            GD.PrintErr($"FunscriptPlayer: JSON parse error in axis script {path}");
            return;
        }

        var funscript = parser.Data.AsGodotDictionary();
        var rawActions = funscript.ContainsKey("actions") ? funscript["actions"].AsGodotArray() : new Godot.Collections.Array();
        foreach (var rawAction in rawActions)
        {
            var action = rawAction.AsGodotDictionary();
            state.Actions.Add(new Action
            {
                AtMs = action.ContainsKey("at") ? action["at"].AsSingle() : 0f,
                Pos = action.ContainsKey("pos") ? action["pos"].AsInt32() : 0,
            });
        }
        _axes[axis] = state;
    }

    // Remove all secondary axis scripts (call before loading a new round).
    public void ClearAxisScripts()
    {
        _axes.Clear();
    }

    // Load a restim (E-Stim Full) axis funscript. `axis` is the restim T-code axis name
    // (e.g. "L0", "V0", "C0", "P1"). Streamed to restim only; supersedes the motion mapping
    // and the manual slider for that axis. Call ClearRestimScripts() before a new round.
    public void LoadRestimScript(string axis, string path)
    {
        var state = new AxisState();
        string absPath = ProjectSettings.GlobalizePath(path);

        using var funscriptFile = FileAccess.Open(absPath, FileAccess.ModeFlags.Read);
        if (funscriptFile == null)
        {
            GD.PrintErr($"FunscriptPlayer: cannot open restim script {axis}: {path}");
            return;
        }

        var parser = new Json();
        if (parser.Parse(funscriptFile.GetAsText()) != Error.Ok)
        {
            GD.PrintErr($"FunscriptPlayer: JSON parse error in restim script {axis}: {path}");
            return;
        }

        var funscript = parser.Data.AsGodotDictionary();
        var rawActions = funscript.ContainsKey("actions") ? funscript["actions"].AsGodotArray() : new Godot.Collections.Array();
        foreach (var rawAction in rawActions)
        {
            var action = rawAction.AsGodotDictionary();
            state.Actions.Add(new Action
            {
                AtMs = action.ContainsKey("at") ? action["at"].AsSingle() : 0f,
                Pos = action.ContainsKey("pos") ? action["pos"].AsInt32() : 0,
            });
        }
        _restimScripts[axis] = state;
    }

    // Remove all restim axis scripts (call before loading a new round).
    public void ClearRestimScripts()
    {
        _restimScripts.Clear();
    }

    // Load a per-channel vibrator funscript. channel: 0 = vib1, 1 = vib2.
    // Call ClearVibScripts() before loading scripts for a new round.
    public void LoadVibScript(int channel, string path)
    {
        var state = new VibState();
        string absPath = ProjectSettings.GlobalizePath(path);
        using var file = FileAccess.Open(absPath, FileAccess.ModeFlags.Read);
        if (file == null)
        {
            GD.PrintErr($"FunscriptPlayer: cannot open vib script ch{channel}: {path}");
            return;
        }
        var parser = new Json();
        if (parser.Parse(file.GetAsText()) != Error.Ok)
        {
            GD.PrintErr($"FunscriptPlayer: JSON parse error in vib script ch{channel}: {path}");
            return;
        }
        var funscript = parser.Data.AsGodotDictionary();
        var rawActions = funscript.ContainsKey("actions") ? funscript["actions"].AsGodotArray() : new Godot.Collections.Array();
        foreach (var rawAction in rawActions)
        {
            var action = rawAction.AsGodotDictionary();
            state.Actions.Add(new Action
            {
                AtMs = action.ContainsKey("at") ? action["at"].AsSingle() : 0f,
                Pos = action.ContainsKey("pos") ? action["pos"].AsInt32() : 0,
            });
        }
        _vibScripts[channel] = state;
    }

    // Remove all vibrator channel scripts (call before loading a new round).
    public void ClearVibScripts()
    {
        _vibScripts.Clear();
    }

    // Send all known axes that have NO loaded script to neutral (50 → 0.5) so the
    // device doesn't stay wherever it was from a previous round.
    // Only runs when at least one axis script is loaded — single-axis devices
    // (which have no axis scripts) receive no unnecessary secondary-axis traffic.
    private void _SendNeutralToUnloadedAxes()
    {
        if (_axes.Count == 0)
            return; // no multi-axis scripts → nothing to park

        var serial = _serial;
        if (serial == null || !serial.SerialConnected)
            return;

        foreach (var axis in KnownAxes)
        {
            if (!_axes.ContainsKey(axis))
                serial.SendAxis(axis, AxisParkMs, 0.5);
        }
        ForgetSentAxes();
    }

    public void Play()
    {
        _playing = true;
        ResolveOutput();
        _clockPrimed = false;  // first SyncTo snaps to the real video position
        _interpIndex = 0;
        _lastSerialTarget = _homePosition;
        _SendNeutralToUnloadedAxes();
        SendRestimManualState();
        _StartEaseIn();
    }

    public void Pause()
    {
        _playing = false;
        _easing = false;
        EaseToNeutral();
    }

    public void Resume()
    {
        _playing = true;
        // Re-resolve in case the user changed the output mode or selected
        // device through the Options overlay while paused. Without this, a
        // device swap mid-round (or mid-transition) keeps sending to the
        // previous device or the wrong capability branch.
        _outputResolved = false;
        ResolveOutput();
        _clockPrimed = false;  // re-lock the smooth clock to the resumed video position
        _interpIndex = 0;
        _lastSerialTarget = _homePosition;
        ForgetSentAxes();  // the pause homed the axes outside the stream
        SendRestimManualState();
        _StartEaseIn();
    }

    public void Stop()
    {
        _playing = false;
        _easing = false;
        _fillerActive = false; // cancel any storyboard filler that may still be running

        // Clear any active override so a run ending mid-takeover doesn't leak override state onto the
        // (autoload) player into the next journey; EaseToNeutral below homes the device.
        _overrideActive = false;
        _overrideImmune = false;
        _savedActions = null;
        _savedAxes = null;
        _savedVibs = null;
        _savedRestim = null;

        EaseToNeutral();
        _positionMs = 0.0;
        _actionIndex = 0;
        _clockPrimed = false;
        _interpIndex = 0;
        _lastSerialTarget = _homePosition;

        foreach (var kv in _axes)
        {
            kv.Value.Index = 0;
            kv.Value.InterpIndex = 0;
        }
        foreach (var kv in _vibScripts)
            kv.Value.Index = 0;
        foreach (var kv in _restimScripts)
            kv.Value.Index = 0;

        // Release constrict actuators before dropping the routes, then reset the state machine.
        var bpc = _buttplug;
        if (bpc != null && bpc.BpConnected)
        {
            foreach (var route in _constrictRoutes)
                bpc.SendConstrictLevel(route.Index, route.Channel, 0);
        }
            
        _constrict.Reset();
        _lastConstrictLevel = -1;
        _strokeActivity = 0.0;

        _strokeBackend = StrokeBackend.None;
        _strokeDeviceIndex = -1;
        _vibeRoutes.Clear();
        _constrictRoutes.Clear();
        _outputResolved = false;
    }

    // ── Override takeover ────────────────────────────────────────────────────────
    // A source-agnostic device takeover (see OVERRIDE_ITEMS_DESIGN.md): pause the round's funscript,
    // play a bundled override on its own clock, then hand control back and re-anchor to the LIVE video
    // position. The GDScript coordinator (GameLoop) owns the lifecycle + the OverrideSession clock and
    // drives these two calls; this is the C# (serial / Buttplug / restim) half of the swap.

    private bool _overrideActive = false;
    private bool _overrideImmune = false;
    private List<Action> _savedActions;
    private System.Collections.Generic.Dictionary<string, AxisState> _savedAxes;
    private System.Collections.Generic.Dictionary<int, VibState> _savedVibs;
    private System.Collections.Generic.Dictionary<string, AxisState> _savedRestim;

    /// True while an override owns the device — the round's own re-anchors stay suppressed until it ends.
    public bool OverrideActive => _overrideActive;

    /// Begins an override: stashes the round's channels, installs the bundle's, resets the clock to the
    /// override's own t=0, and eases in. Channels the bundle doesn't define are parked to neutral.
    /// `mainPts` is Array[Vector2(at_ms, pos)]; `axisPts` is {axis_name: Array[Vector2]}; `vibPts` is
    /// {channel(int): Array[Vector2]}. `immune` makes the override ignore active stroke effects/curses.
    public void BeginOverride(Godot.Collections.Array mainPts, Godot.Collections.Dictionary axisPts,
        Godot.Collections.Dictionary vibPts, bool immune)
    {
        if (!_overrideActive) // first takeover — a REPLACE keeps the existing round stash
        {
            _savedActions = _actions;
            _savedAxes = new System.Collections.Generic.Dictionary<string, AxisState>(_axes);
            _savedVibs = new System.Collections.Generic.Dictionary<int, VibState>(_vibScripts);
            _savedRestim = new System.Collections.Generic.Dictionary<string, AxisState>(_restimScripts);
        }

        _actions = ActionsFromPoints(mainPts);
        _axes.Clear();
        if (axisPts != null)
            foreach (var key in axisPts.Keys)
                _axes[key.AsString()] = new AxisState { Actions = ActionsFromPoints(axisPts[key].AsGodotArray()) };
        _vibScripts.Clear();
        if (vibPts != null)
            foreach (var key in vibPts.Keys)
                _vibScripts[key.AsInt32()] = new VibState { Actions = ActionsFromPoints(vibPts[key].AsGodotArray()) };
        _restimScripts.Clear(); // the override's main stroke drives restim L0; no dedicated estim scripts

        _ExtractBeats();

        _positionMs = 0.0;
        _actionIndex = 0;
        _interpIndex = 0;
        _clockPrimed = false;
        // _lastSerialTarget is deliberately NOT reset — it holds the device's current stroke position so
        // _StartEaseIn below eases the override IN from there instead of snapping via home.
        _strokeActivity = 0.0;

        _overrideActive = true;
        _overrideImmune = immune;
        _playing = true;

        _ParkUndefinedOverrideChannels();
        _StartEaseIn();
    }

    /// Ends the override and restores the round's channels, then re-anchors to where the video is NOW
    /// (`resumeVideoSec`) — it kept playing under the override — seeking the play cursors silently so the
    /// skipped stretch is neither scored nor blasted out in one catch-up frame.
    public void EndOverride(double resumeVideoSec)
    {
        if (!_overrideActive)
            return;

        _actions = _savedActions ?? new List<Action>();
        _savedActions = null;
        _axes.Clear();
        if (_savedAxes != null)
            foreach (var kv in _savedAxes)
                _axes[kv.Key] = kv.Value;
        _vibScripts.Clear();
        if (_savedVibs != null)
            foreach (var kv in _savedVibs)
                _vibScripts[kv.Key] = kv.Value;
        _restimScripts.Clear();
        if (_savedRestim != null)
            foreach (var kv in _savedRestim)
                _restimScripts[kv.Key] = kv.Value;
        _savedAxes = null;
        _savedVibs = null;
        _savedRestim = null;
        ForgetSentAxes();  // the override parked or drove these axes; resend the round's positions

        _ExtractBeats();

        double posMs = resumeVideoSec * 1000.0;
        _positionMs = posMs;
        _SeekIndicesTo(posMs);
        _clockPrimed = true;
        // Keep _lastSerialTarget (the override's last position) so the round eases back IN from there.

        _overrideActive = false;
        _overrideImmune = false;

        _StartEaseIn();
    }

    // Effects the OUTPUT path should honour: NONE while an immune override is active (it ignores
    // items / curses / boss modifiers, including block and mirror), else the live inventory set.
    private Godot.Collections.Array ActiveEffectsForOutput()
    {
        if (_overrideActive && _overrideImmune)
            return null;
        return _inventory?.GetActiveEffects();
    }

    // Builds a List<Action> from an Array[Vector2(at_ms, pos)] the coordinator passes in.
    private static List<Action> ActionsFromPoints(Godot.Collections.Array pts)
    {
        var list = new List<Action>();
        if (pts == null)
            return list;
        foreach (var p in pts)
        {
            Vector2 v = p.AsVector2();
            list.Add(new Action { AtMs = v.X, Pos = (int)Math.Round(v.Y) });
        }
        return list;
    }

    // Eases every channel the override does NOT define toward neutral (serial axes + mapped restim
    // motion axes to centre; vibe1/vibe2 actuators with no override script silenced). The stroke and
    // any follow-stroke vibe keep tracking the override.
    private void _ParkUndefinedOverrideChannels()
    {
        var serial = _serial;
        if (serial != null && serial.SerialConnected)
            foreach (var axis in KnownAxes)
                if (!_axes.ContainsKey(axis))
                    serial.SendAxis(axis, _homeEaseMs, 0.5);

        var restim = _restim;
        if (restim != null && restim.RestimConnected)
            foreach (var kv in RestimService.MotionAxisMap)
                if (!_axes.ContainsKey(kv.Key))
                    restim.SendTCode(kv.Value, 0.5, _homeEaseMs);

        var bp = _buttplug;
        if (bp != null && bp.BpConnected)
            foreach (var route in _vibeRoutes)
                if ((route.Source == "vibe1" && !_vibScripts.ContainsKey(0))
                    || (route.Source == "vibe2" && !_vibScripts.ContainsKey(1)))
                    bp.SendVibrateChannel(route.Index, route.Channel, 0.0);

        ForgetSentAxes();
    }

    // Fast-forwards every channel's play cursor to `posMs` WITHOUT dispatching (no scoring, no sends),
    // so re-anchoring after an override doesn't replay the stretch that ran underneath it.
    private void _SeekIndicesTo(double posMs)
    {
        _actionIndex = SkipTo(_actions, posMs);
        _interpIndex = Math.Max(0, _actionIndex - 1);
        foreach (var kv in _axes)
        {
            kv.Value.Index = SkipTo(kv.Value.Actions, posMs);
            kv.Value.InterpIndex = Math.Max(0, kv.Value.Index - 1);
        }
        foreach (var kv in _vibScripts)
            kv.Value.Index = SkipTo(kv.Value.Actions, posMs);
        foreach (var kv in _restimScripts)
            kv.Value.Index = SkipTo(kv.Value.Actions, posMs);
    }

    // Count of actions already elapsed at `posMs` (points are time-sorted) — the cursor value the
    // per-frame play loops expect for that clock position.
    private static int SkipTo(List<Action> actions, double posMs)
    {
        int i = 0;
        while (i < actions.Count && actions[i].AtMs <= posMs)
            i++;
        return i;
    }

    // Begin the storyboard filler: alternating hi→lo→hi strokes at the given
    // half-cycle speed. Respects the device range clamp but not inventory effects.
    // lo/hi are in the same 0–100 scale as funscript positions.
    // Live setter for filler parameters. Used by the Options overlay so a user
    // tweaking the storyboard-filler sliders during an active storyboard sees
    // the device respond immediately rather than having to wait for the next
    // storyboard's filler to start. Safe to call any time; if filler isn't
    // running these values are seeded for the next StartFiller call.
    public void SetFillerParams(int lo, int hi, int halfCycleMs)
    {
        _fillerLo = lo;
        _fillerHi = hi;
        _fillerHalfCycleMs = Math.Max(100, halfCycleMs);
    }


    public void StartFiller(int lo, int hi, int halfCycleMs)
    {
        _fillerLo = lo;
        _fillerHi = hi;
        _fillerHalfCycleMs = Math.Max(100, halfCycleMs);
        _fillerElapsedMs = 0.0;
        _fillerGoingToLo = false; // first stroke goes to hi, then alternates
        _fillerVibTickMs = 0.0;
        _fillerActive = true;
        ResolveOutput();
        SendRestimManualState();
        _SendFillerCommand(); // fire immediately so there's no leading silence
    }

    // Stop the filler and ease the device back to neutral.
    public void StopFiller()
    {
        if (!_fillerActive) return;
        _fillerActive = false;
        EaseToNeutral();
    }

    // Compute ease-in parameters from the first upcoming script action.
    // Duration is proportional to how far that position is from neutral (50),
    // so the device always approaches at a consistent speed regardless of gap size.
    // Skipped entirely for vibrators — intensity jumps are not jarring the way
    // sudden linear strokes are, so no ease is needed.
    private void _StartEaseIn()
    {
        if (_strokeBackend == StrokeBackend.None)
            return; // no stroke target: nothing to ease

        if (_actions.Count == 0)
            return;

        // Ease FROM where the device currently is (last commanded stroke) so a mid-round override — or one
        // override replacing another — glides into the new script instead of snapping via home.
        _easeFromPos = (float)_lastSerialTarget;
        int idx = Math.Min(_actionIndex, _actions.Count - 1);
        float gap = Math.Abs(_actions[idx].Pos - _easeFromPos);

        if (gap <= 2f)
        {
            _easing = false;
            return;
        }

        _easeDurationMs = Math.Clamp(gap / EaseSpeedUnitsPerMs, EaseMinMs, EaseMaxMs);
        _easeStartMs = _positionMs;
        _easing = true;
    }

    // Send a gentle "go to neutral" command so the device doesn't stay
    // mid-stroke or vibrating when playback halts. Linear → midpoint,
    // vibrator → 0 intensity. Safe to call when nothing is connected.
    // For serial devices, all loaded secondary axes are also returned to 0.5.
    private void EaseToNeutral()
    {
        ResolveOutput();

        double homeNorm = _homePosition / 100.0;

        // Stroke target homes to the user position.
        if (_strokeBackend == StrokeBackend.Serial)
        {
            var serial = _serial;
            if (serial != null && serial.SerialConnected)
                serial.SendLinear(_homeEaseMs, homeNorm);
        }
        else if (_strokeBackend == StrokeBackend.Buttplug)
        {
            var bp = _buttplug;
            if (bp != null && bp.BpConnected && _strokeDeviceIndex >= 0)
                bp.SendLinear(_strokeDeviceIndex, _homeEaseMs, homeNorm);
        }

        // Secondary axes (serial) always return to centre.
        var serialAx = _serial;
        if (serialAx != null && serialAx.SerialConnected)
            foreach (var axis in _axes.Keys)
                serialAx.SendAxis(axis, _homeEaseMs, 0.5);

        // Auto Twist is not in _axes, so the loop above never reaches it. Centre it the same way — unless
        // an authored R0 is loaded, in which case that loop already did.
        if (_autoTwistDriving && !_axes.ContainsKey("R0") && serialAx != null && serialAx.SerialConnected)
            serialAx.SendAxis("R0", _homeEaseMs, 0.5);
        _autoTwistDriving = false;
        _lastAutoTwist = 50.0;
        ForgetSentAxes();

        // Silence every mapped vibe actuator.
        var bpv = _buttplug;
        if (bpv != null && bpv.BpConnected)
            foreach (var route in _vibeRoutes)
                bpv.SendVibrateChannel(route.Index, route.Channel, 0.0);

        // restim: position axes home (L0 → user home, mapped motion axes → centre).
        var restim = _restim;
        if (restim != null && restim.RestimConnected)
        {
            restim.SendTCode(RestimService.StrokeAxis, homeNorm, _homeEaseMs);
            foreach (var kv in RestimService.MotionAxisMap)
                if (_axes.ContainsKey(kv.Key))
                    restim.SendTCode(kv.Value, 0.5, _homeEaseMs);
        }
    }

    // Call this each frame from GameLoop to keep funscript in sync with the video clock.
    // Only reconciles _positionMs — _Process and _PhysicsProcess dispatch/stream the output.
    public void SyncTo(double videoPositionSec)
    {
        // While an override owns the device it runs on its OWN clock — ignore the video position until
        // EndOverride re-anchors (the override drives _positionMs via the free-run in _PhysicsProcess).
        if (_overrideActive)
            return;

        // Reconcile our smooth clock toward the video instead of hard-snapping every frame: the raw
        // video position steps a whole frame at a time and jitters, which the stroker would faithfully
        // reproduce. The first sample after a (re)start, or any large gap (a seek), snaps; otherwise we
        // close a fraction of the error, staying locked without inheriting the steps. Per-backend
        // delay is applied per stream downstream, not baked in here.
        double videoMs = videoPositionSec * 1000.0;
        double error = videoMs - _positionMs;
        if (!_clockPrimed || Math.Abs(error) > ClockResyncThresholdMs)
        {
            _positionMs = videoMs;
            _clockPrimed = true;
        }
        else
        {
            _positionMs += error * ClockReconcileGain;
        }
    }

    // Moves the play clock AND every channel's cursor to a new video position without dispatching
    // anything in between. SyncTo deliberately only moves the clock, so after a jump the per-frame loop
    // in _Process would walk every keyframe it had skipped and score them all in a single frame — a
    // 30-second region skip landing 30 seconds of strokes at once, which in a boss round reads as the
    // health bar collapsing. Any code that MOVES the playhead must call this instead of relying on the
    // next SyncTo to notice.
    public void SeekTo(double videoPositionSec)
    {
        // An override owns the clock while it runs; EndOverride re-anchors the cursors itself.
        if (_overrideActive)
            return;

        double posMs = videoPositionSec * 1000.0;
        _positionMs = posMs;
        _SeekIndicesTo(posMs);
        _clockPrimed = true;
    }

    public override void _Process(double delta)
    {
        // Runs whenever playing — not gated on _actions having content, so vib /
        // axis scripts still dispatch even if the main L0 script is empty.
        if (_playing)
        {
            // The stroke clock is advanced in _PhysicsProcess at the fixed physics rate (regular,
            // decoupled from render FPS) — here we only dispatch the per-keyframe work against it:
            // scoring, activity, follow-stroke vibe, and (Buttplug only) the stroke send. The SERIAL
            // stroke position is streamed in _PhysicsProcess too.
            // A positive delay holds each action back (fires it LATER); negative fires it ahead.
            double strokeDelay = StrokeDelay();
            while (_actionIndex < _actions.Count)
            {
                if (_actions[_actionIndex].AtMs > _positionMs - strokeDelay)
                    break;

                ProcessKeyframe(_actionIndex);
                _actionIndex++;
            }

            // Secondary axes → restim, one move per keyframe, under the E-Stim Full mapped name
            // (surge→L1, twist→C0, pitch→P0, sway→V1, roll→V2). The SERIAL device gets these axes from
            // the per-tick stream in _PhysicsProcess instead. The cursors advance whether or not restim
            // is connected, so connecting mid-round never replays the keyframes that already passed.
            {
                var restim = _restim;
                bool restimOn = restim != null && restim.RestimConnected;
                double easeBlend = EaseBlend();
                foreach (var multiaxis in _axes)
                {
                    string axis = multiaxis.Key;
                    AxisState state = multiaxis.Value;
                    while (state.Index < state.Actions.Count)
                    {
                        if (state.Actions[state.Index].AtMs > _positionMs - _serialDelayMs)
                            break;

                        int idx = state.Index;
                        if (restimOn && idx + 1 < state.Actions.Count
                            && RestimService.MotionAxisMap.TryGetValue(axis, out string rax)
                            && !_restimScripts.ContainsKey(rax))
                        {
                            (int axisMin, int axisMax) = GetAxisRange(axis);
                            double pos = SecondaryAxisOutput(state.Actions[idx + 1].Pos, axisMin, axisMax, easeBlend);
                            uint durMs = (uint)Math.Max(1, (int)(state.Actions[idx + 1].AtMs - state.Actions[idx].AtMs));
                            restim.SendTCode(rax, Math.Round(pos) / 100.0, durMs);
                        }
                        state.Index++;
                    }
                }
            }

            // restim dedicated axis scripts (E-Stim Full: alpha/beta/volume/carrier_frequency/…) → restim,
            // on the L0 clock. restim-only; each overrides the motion mapping + manual slider for its axis.
            {
                var restim = _restim;
                if (restim != null && restim.RestimConnected && _restimScripts.Count > 0)
                {
                    foreach (var kv in _restimScripts)
                    {
                        string rax = kv.Key;
                        AxisState state = kv.Value;
                        while (state.Index < state.Actions.Count)
                        {
                            if (state.Actions[state.Index].AtMs > _positionMs)
                                break;

                            int idx = state.Index;
                            if (idx + 1 < state.Actions.Count)
                            {
                                double targetNorm = Math.Clamp(state.Actions[idx + 1].Pos, 0, 100) / 100.0;
                                uint durMs = (uint)Math.Max(1, (int)(state.Actions[idx + 1].AtMs - state.Actions[idx].AtMs));
                                restim.SendTCode(rax, targetNorm, durMs);
                            }
                            state.Index++;
                        }
                    }
                }
            }

            // Vibe scripts (vibe1 / vibe2) → their mapped actuators, on the same clock as L0.
            if (_vibScripts.Count > 0)
            {
                foreach (var vibEntry in _vibScripts)
                {
                    string source = vibEntry.Key == 0 ? "vibe1" : "vibe2";
                    var vstate = vibEntry.Value;
                    while (vstate.Index < vstate.Actions.Count)
                    {
                        if (vstate.Actions[vstate.Index].AtMs > _positionMs - _intifaceDelayMs)
                            break;

                        double intensity = vstate.Actions[vstate.Index].Pos / 100.0 * _vibeIntensity;
                        SendToVibeSource(source, intensity);
                        vstate.Index++;
                    }
                }
            }
        }

        // Storyboard filler runs independently of normal funscript playback.
        if (_fillerActive)
        {
            _fillerElapsedMs += delta * 1000.0;
            if (_fillerElapsedMs >= _fillerHalfCycleMs)
            {
                _fillerElapsedMs -= _fillerHalfCycleMs;
                _fillerGoingToLo = !_fillerGoingToLo;
                _SendFillerCommand();
            }

            // Vibrators can't interpolate — update mapped actuators frequently with a triangle wave.
            if (_vibeRoutes.Count > 0)
            {
                _fillerVibTickMs += delta * 1000.0;
                if (_fillerVibTickMs >= FillerVibTickIntervalMs)
                {
                    _fillerVibTickMs = 0.0;
                    _SendFillerVibrateTick();
                }
            }
        }

        // Constrict auto state machine — throttled; runs even while paused so it can hold/release.
        if (_constrictRoutes.Count > 0)
        {
            _constrictTickMs += delta * 1000.0;
            if (_constrictTickMs >= ConstrictTickIntervalMs)
            {
                double dt = _constrictTickMs;
                _constrictTickMs = 0.0;

                // Decay activity so gaps between keyframes wind it down toward release.
                _strokeActivity *= Math.Pow(0.5, dt / ActivityDecayHalfLifeMs);
                double lastMs = _actions.Count > 0 ? _actions[_actions.Count - 1].AtMs : 0.0;
                double progressPct = lastMs > 0.0 ? Math.Clamp(_positionMs / lastMs * 100.0, 0.0, 100.0) : 0.0;
                _constrict.Update(dt, _strokeActivity, progressPct, _playing);

                if (_constrict.Level != _lastConstrictLevel)
                {
                    _lastConstrictLevel = _constrict.Level;
                    var bpc = _buttplug;
                    if (bpc != null && bpc.BpConnected)
                        foreach (var route in _constrictRoutes)
                            bpc.SendConstrictLevel(route.Index, route.Channel, _constrict.Level);
                }
            }
        }
    }

    // Streams the SERIAL stroke position at the fixed physics rate. Instead of forwarding raw
    // keyframes on the coarse, jittery video clock, we sample the script at the current time every
    // tick and send one interval-move — a steady, high-rate stream the OSR/SR6 glides along. This is
    // the core of MultiFunPlayer-style smoothness. Serial only: Buttplug/BLE can't take this rate and
    // stays on the per-keyframe path in ProcessKeyframe.
    public override void _PhysicsProcess(double delta)
    {
        // Advance the smooth stroke clock HERE, at the fixed physics rate: a regular cadence decoupled
        // from render FPS and the coarse video frame clock, so the interpolated target actually moves
        // every tick. SyncTo nudges it toward the video; funscript-only (free-run) mode relies on it
        // entirely. Runs for every backend, before the serial-streaming early-out below.
        if (_playing)
        {
            _positionMs += delta * 1000.0;
            if (_easing && _positionMs - _easeStartMs >= _easeDurationMs)
                _easing = false;
        }

        if (!_playing)
            return;

        var serial = _serial;
        if (serial == null || !serial.SerialConnected)
            return;

        double now = _positionMs - _serialDelayMs;
        _tickAxes.Clear();
        _tickPositions.Clear();

        var effects = ActiveEffectsForOutput();
        UpdateAxisMirrorBlend(effects); // clock-driven; advance once per tick, even while axes are held
        // Stilled: every axis but the stroke holds where it is — the axis twin of the stroke's block.
        bool axesHeld = CountKind(effects, "axis_block") > 0;

        if (_strokeBackend == StrokeBackend.Serial && _actions.Count > 0)
            QueueStrokeTick(now, delta, effects, axesHeld);
        if (!axesHeld)
            QueueAuthoredAxes(now, effects);

        // Interval a touch longer than the tick so the OSR is always still gliding toward a fresh
        // target instead of finishing early and dwelling (which would re-introduce stepping).
        uint intervalMs = (uint)Math.Max(1, Math.Round(delta * 1000.0 * _serialInterpFactor));
        serial.SendMoves(_tickAxes, _tickPositions, intervalMs);
    }

    // The stroke, plus Auto Twist riding it. Only when the stroke's backend is serial and there is a main
    // track; a block effect holds both where they are.
    private void QueueStrokeTick(double now, double delta, Godot.Collections.Array effects, bool axesHeld)
    {
        UpdateMirrorBlend(effects); // clock-driven; advance once per tick, even under block

        if (effects != null && HasBlockEffect(effects))
            return; // block suppresses output — hold position

        // Move the bracket cursor to the segment containing `now` (both directions, so seeks recover).
        while (_interpIndex + 1 < _actions.Count && _actions[_interpIndex + 1].AtMs <= now)
            _interpIndex++;
        while (_interpIndex > 0 && _actions[_interpIndex].AtMs > now)
            _interpIndex--;

        double target = InterpolatedStrokePos(now, effects);

        // Max stroke speed: cap how far the target can move this tick, so aggressive scripts are
        // gently slowed rather than snapped (the interp equivalent of _CapDuration).
        if (_maxStrokeSpeed > 0)
        {
            double maxDelta = _maxStrokeSpeed * delta;
            target = Math.Clamp(target, _lastSerialTarget - maxDelta, _lastSerialTarget + maxDelta);
        }
        _lastSerialTarget = target;

        double sent = Math.Clamp(target, 0.0, 100.0);
        QueueMove("L0", sent);

        // Auto Twist rides the stroke it was derived from: the same value, after every effect and the
        // speed cap above, so anything that reshapes the stroke reshapes the twist. Block returned early,
        // so a blocked stroke holds the twist too.
        if (AutoTwistActive() && !axesHeld)
            QueueAutoTwist(StrokeInScriptSpace(sent, _rangeMin, _rangeMax), delta, effects);
    }

    // Every authored secondary axis at `now`, whatever the stroke is doing: they play on under a block
    // and with the stroke on another backend, exactly as the per-keyframe path they replace did. An axis
    // whose position hasn't changed since it was last sent is left off the line.
    private void QueueAuthoredAxes(double now, Godot.Collections.Array effects)
    {
        if (_axes.Count == 0)
            return;

        if (++_ticksSinceAxisResend >= AxisResendTicks)
        {
            _ticksSinceAxisResend = 0;
            ForgetSentAxes();
        }

        double easeBlend = EaseBlend();
        foreach (var multiaxis in _axes)
        {
            AxisState state = multiaxis.Value;
            if (state.Actions.Count == 0)
                continue;

            string axis = multiaxis.Key;
            (int axisMin, int axisMax) = GetAxisRange(axis);
            double scriptPos = SampleActions(state.Actions, ref state.InterpIndex, now);
            double modified = AxisModifiedPos(axis, scriptPos, effects, _axisMirrorBlend);
            double pos = SecondaryAxisOutput(modified, axisMin, axisMax, easeBlend);

            int steps = (int)Math.Round(pos / 100.0 * 9999.0);
            if (_lastSentAxisSteps.TryGetValue(axis, out int lastSteps) && lastSteps == steps)
                continue;
            _lastSentAxisSteps[axis] = steps;
            QueueMove(axis, pos);
        }
    }

    // Send a single linear command to the device for the current filler direction.
    private void _SendFillerCommand()
    {
        int target = _fillerGoingToLo ? _fillerLo : _fillerHi;
        target = Math.Clamp(target, _rangeMin, _rangeMax);
        uint dur = (uint)_fillerHalfCycleMs;

        // Linear filler → the stroke target. Vibrators are handled by _SendFillerVibrateTick.
        if (_strokeBackend == StrokeBackend.Serial)
        {
            var serial = _serial;
            if (serial != null && serial.SerialConnected)
                serial.SendLinear(dur, target / 100.0);
        }
        else if (_strokeBackend == StrokeBackend.Buttplug)
        {
            var bp = _buttplug;
            if (bp != null && bp.BpConnected && _strokeDeviceIndex >= 0)
                bp.SendLinear(_strokeDeviceIndex, dur, target / 100.0);
        }
    }

    // Compute current triangle-wave intensity for a vibrator and send it.
    private void _SendFillerVibrateTick()
    {
        double t = Math.Clamp(_fillerElapsedMs / _fillerHalfCycleMs, 0.0, 1.0);
        double fromPos = _fillerGoingToLo ? _fillerHi : _fillerLo;
        double toPos = _fillerGoingToLo ? _fillerLo : _fillerHi;
        double pos = fromPos + (toPos - fromPos) * t;
        pos = Math.Clamp(pos, _rangeMin, _rangeMax);

        // Filler ignores per-actuator source (it's a global idle wave) → drive every vibe actuator.
        var bp = _buttplug;
        if (bp == null || !bp.BpConnected)
            return;
        double intensity = Math.Clamp(pos / 100.0 * _vibeIntensity, 0.0, 1.0);
        foreach (var route in _vibeRoutes)
            bp.SendVibrateChannel(route.Index, route.Channel, intensity);
    }

    private void ResolveOutput()
    {
        if (_outputResolved)
            return;

        // Cache device range limits so per-keyframe processing doesn't hit disk per-action.
        _rangeMin = _settings.Call("get_range_min").AsInt32();
        _rangeMax = _settings.Call("get_range_max").AsInt32();

        // Seed each secondary positional axis's own range window (SetAxisRangeClamp
        // overrides live from Options). KnownAxes = the T-code names we dispatch.
        foreach (var axis in KnownAxes)
            _axisRanges[axis] = (
                _settings.Call("get_axis_range_min", axis).AsInt32(),
                _settings.Call("get_axis_range_max", axis).AsInt32());

        // Cache home-position config. SetHomePosition() can override these live
        // (called by Options on every slider change), but we also read them here
        // so the first round after a fresh launch picks up the saved values.
        _homePosition = Math.Clamp(_settings.Call("get_home_position").AsInt32(), 0, 100);
        _homeEaseMs = (uint)Math.Max(50, _settings.Call("get_home_ease_ms").AsInt32());

        // Cache per-backend output delays + vibrator intensity scale. All can be overridden live via
        // their setters, but seed from disk here. The delay getters default to the legacy
        // latency_offset_ms, so existing setups carry their tuned value forward.
        _serialDelayMs = _settings.Call("get_serial_delay_ms").AsInt32();
        _intifaceDelayMs = _settings.Call("get_intiface_delay_ms").AsInt32();
        _vibeIntensity = Math.Clamp(_settings.Call("get_vibe_intensity").AsInt32(), 0, 100) / 100f;
        _maxStrokeSpeed = Math.Max(0, _settings.Call("get_max_stroke_speed").AsInt32());
        _autoTwistGain = Math.Clamp(_settings.Call("get_auto_twist_gain").AsDouble(), 0.0, 1.0);
        _serialInterpFactor = _settings.Call("get_serial_interp_factor").AsDouble();

        // Seed the constrict state machine's tuning from settings.
        _constrict.MaxLevel = _settings.Call("get_constrict_max_level").AsInt32();
        _constrict.L1Threshold = _settings.Call("get_constrict_level1_threshold").AsDouble();
        _constrict.L1SustainMs = _settings.Call("get_constrict_level1_sustain_ms").AsInt32();
        _constrict.ReleaseThreshold = _settings.Call("get_constrict_release_threshold").AsDouble();
        _constrict.ReleaseSustainMs = _settings.Call("get_constrict_release_sustain_ms").AsInt32();
        _constrict.MinHoldMs = _settings.Call("get_constrict_min_hold_ms").AsInt32();
        _constrict.L2Enabled = _settings.Call("get_constrict_level2_enabled").AsBool();
        _constrict.L2Threshold = _settings.Call("get_constrict_level2_threshold").AsDouble();
        _constrict.L2SustainMs = _settings.Call("get_constrict_level2_sustain_ms").AsInt32();
        _constrict.L2FinalPct = _settings.Call("get_constrict_level2_final_percent").AsDouble();
        _constrict.HoldOnPause = _settings.Call("get_constrict_hold_on_pause").AsBool();

        BuildRoutingPlan();
        _outputResolved = true;
    }

    // Rebuilds the stroke target + vibe routes from the saved routing config, resolved (by the pure
    // GDScript resolver) against the live Buttplug catalog. Falls back to the legacy
    // output_mode / selected_device when no routing has been configured yet, so existing single-device
    // setups keep working until they map devices in Options (Slice 4).
    private void BuildRoutingPlan()
    {
        _strokeBackend = StrokeBackend.None;
        _strokeDeviceIndex = -1;
        _vibeRoutes.Clear();
        _constrictRoutes.Clear();

        string strokeTarget = _settings.Call("get_stroke_target").AsString();
        var vibRoutes = _settings.Call("get_vibration_routes").AsGodotDictionary();
        var constrictRoutes = _settings.Call("get_constrict_routes").AsGodotDictionary();

        if (string.IsNullOrEmpty(strokeTarget) && vibRoutes.Count == 0)
        {
            BuildLegacyPlan();
            return;
        }

        var catalog = _buttplug != null ? _buttplug.GetDeviceCatalog() : new Godot.Collections.Array();
        var plan = _deviceRoutingScript
            .Call("resolve", strokeTarget, vibRoutes, constrictRoutes, catalog)
            .AsGodotDictionary();

        var stroke = plan["stroke"].AsGodotDictionary();
        if (stroke.Count > 0)
        {
            string backend = stroke["backend"].AsString();
            if (backend == "serial")
            {
                _strokeBackend = StrokeBackend.Serial;
            }
            else if (backend == "bp" && _buttplug != null)
            {
                int idx = _buttplug.GetDeviceIndexById(stroke["device"].AsString());
                if (idx >= 0)
                {
                    _strokeBackend = StrokeBackend.Buttplug;
                    _strokeDeviceIndex = idx;
                }
            }
        }

        foreach (var v in plan["vibration"].AsGodotArray())
        {
            var route = v.AsGodotDictionary();
            int idx = _buttplug != null ? _buttplug.GetDeviceIndexById(route["device"].AsString()) : -1;
            if (idx >= 0)
                _vibeRoutes.Add((idx, route["channel"].AsInt32(), route["source"].AsString()));
        }

        foreach (var c in plan["constrict"].AsGodotArray())
        {
            var route = c.AsGodotDictionary();
            int idx = _buttplug != null ? _buttplug.GetDeviceIndexById(route["device"].AsString()) : -1;
            if (idx >= 0)
                _constrictRoutes.Add((idx, route["channel"].AsInt32()));
        }
    }

    // Backward-compat: derive a plan from the pre-routing output_mode / selected_device so a user who
    // hasn't opened the new routing UI keeps their existing single device. Removed once routing is the
    // only path (Slice 4+).
    private void BuildLegacyPlan()
    {
        string mode = _settings.Call("get_output_mode").AsString();
        if (mode == "serial")
        {
            _strokeBackend = StrokeBackend.Serial;
            return;
        }

        var bp = _buttplug;
        if (bp == null)
            return;
        int idx = bp.GetSelectedDeviceIndex();
        if (idx < 0)
            return;

        if (bp.DeviceSupportsLinear(idx))
        {
            _strokeBackend = StrokeBackend.Buttplug;
            _strokeDeviceIndex = idx;
        }
        else
        {
            // Vibrator: map each channel to its vib script, else follow the stroke — mirrors old behaviour.
            int channels = Math.Max(1, bp.GetVibrationChannelCount(idx));
            for (int ch = 0; ch < channels; ch++)
            {
                string source;
                if (_vibScripts.ContainsKey(ch))
                    source = ch == 0 ? "vibe1" : "vibe2";
                else if (_vibScripts.Count > 0)
                    source = "vibe1";
                else
                    source = "stroke";
                _vibeRoutes.Add((idx, ch, source));
            }
        }
    }

    // Per-keyframe work shared by every backend: scoring, smoothed activity (for constrict), and
    // follow-stroke vibe — plus, for Buttplug, the linear stroke send. The SERIAL stroke position is
    // NOT sent here; it's streamed continuously in _PhysicsProcess. A block effect suppresses
    // everything (scoring, vibe, send), same as before.
    private void ProcessKeyframe(int index)
    {
        ResolveOutput();
        var effects = ActiveEffectsForOutput();

        // Serial advances the eased mirror factor in its physics tick; every other backend advances
        // it here — before the block early-out, so it keeps settling even while block suppresses output.
        if (_strokeBackend != StrokeBackend.Serial)
            UpdateMirrorBlend(effects);

        if (effects != null && HasBlockEffect(effects))
            return;

        // Score + activity from the post-effects amplitude BEFORE the comfort range-clamp, so
        // narrowing the range to taste never costs points (range is comfort, not difficulty).
        if (index + 1 < _actions.Count)
        {
            int cur = TransformPos(index, effects);
            int nxt = TransformPos(index + 1, effects);
            _score?.AddStroke(Math.Abs(nxt - cur));

            double segMs = _actions[index + 1].AtMs - _actions[index].AtMs;
            double speed = segMs > 0.0 ? Math.Abs(_actions[index + 1].Pos - _actions[index].Pos) / (segMs / 1000.0) : 0.0;
            _strokeActivity += (speed - _strokeActivity) * 0.5;
        }

        // Follow-stroke vibe actuators track the commanded stroke position as intensity.
        int currentPos = ProcessedStrokePos(index, effects);
        SendToVibeSource("stroke", currentPos / 100.0 * _vibeIntensity);

        // restim (e-stim) runs in parallel with the stroke backend: the stroke funscript drives
        // restim's Alpha (L0). Deliberately outside the _strokeBackend branch so it still works
        // when the serial device is off (serial is turned off once restim connects). Sent per
        // keyframe with a duration rather than streamed — T-code does the tweening device-side.
        SendRestimStroke(index, effects);

        // Buttplug linear stroke: one interval-move per keyframe (BLE can't take the serial rate).
        if (_strokeBackend == StrokeBackend.Buttplug)
            SendButtplugStroke(index, effects);
    }

    // Stroke-axis (Alpha/L0) send to restim for one keyframe, mirroring SendButtplugStroke. Skipped
    // when the round ships a dedicated estim script for the axis — that script wins over the stroke.
    private void SendRestimStroke(int index, Godot.Collections.Array effects)
    {
        var restim = _restim;
        if (restim == null || !restim.RestimConnected)
            return;
        if (_restimScripts.ContainsKey(RestimService.StrokeAxis))
            return;
        if (index + 1 >= _actions.Count)
            return;

        int currentPos = ProcessedStrokePos(index, effects);
        int nextPos = ProcessedStrokePos(index + 1, effects);
        uint durationMs = (uint)Math.Max(1, (int)(_actions[index + 1].AtMs - _actions[index].AtMs));
        durationMs = _CapDuration(currentPos, nextPos, durationMs);
        restim.SendTCode(RestimService.StrokeAxis, nextPos / 100.0, durationMs);
    }

    // Buttplug linear stroke send for one keyframe: move toward the next processed position over the
    // inter-keyframe interval (capped by max stroke speed).
    private void SendButtplugStroke(int index, Godot.Collections.Array effects)
    {
        if (index + 1 >= _actions.Count)
            return;
        int currentPos = ProcessedStrokePos(index, effects);
        int nextPos = ProcessedStrokePos(index + 1, effects);
        uint durationMs = (uint)Math.Max(1, (int)(_actions[index + 1].AtMs - _actions[index].AtMs));
        durationMs = _CapDuration(currentPos, nextPos, durationMs);

        var bp = _buttplug;
        if (bp != null && bp.BpConnected && _strokeDeviceIndex >= 0)
            bp.SendLinear(_strokeDeviceIndex, durationMs, nextPos / 100.0);
    }

    // The fully-processed device position (0–100) for keyframe `index`: effects → comfort range
    // (RESCALE, not clamp, so strokes keep their shape at reduced amplitude) → ease-from-home →
    // safety clamp. Exactly what the device is told to reach at that keyframe; the serial interp tick
    // lerps between consecutive values of it.
    private int ProcessedStrokePos(int index, Godot.Collections.Array effects)
    {
        int pos = TransformPos(index, effects);
        pos = RescaleToRange(pos);
        pos = ApplyEase(pos);
        return Math.Clamp(pos, _rangeMin, _rangeMax);
    }

    // Ease-in blend from the home position toward `pos`, over the computed ease window. Time-driven
    // (reads _positionMs); the flag itself is cleared in _PhysicsProcess once the window elapses, so
    // this stays a pure map that both the keyframe path and the serial interp tick can call freely.
    private int ApplyEase(int pos)
    {
        if (!_easing)
            return pos;
        double elapsed = _positionMs - _easeStartMs;
        float t = (float)Math.Clamp(elapsed / _easeDurationMs, 0.0, 1.0);
        float smooth = t * t * (3f - 2f * t); // smoothstep (ease-in-out Hermite) — natural for device motion
        return (int)Math.Round(_easeFromPos + (pos - _easeFromPos) * smooth);
    }

    // Linearly interpolates the processed stroke position at `now` between the bracketing keyframes
    // (cursor _interpIndex). Interpolating the PROCESSED endpoints traces the same straight line the
    // OSR firmware already tweens between keyframes — just sampled continuously — so dense/fast
    // sections stay smooth and command timing no longer follows the video frame clock.
    private int InterpolatedStrokePos(double now, Godot.Collections.Array effects)
    {
        if (now <= _actions[0].AtMs)
            return ProcessedStrokePos(0, effects);
        int i = _interpIndex;
        if (i + 1 >= _actions.Count)
            return ProcessedStrokePos(_actions.Count - 1, effects);

        double a = _actions[i].AtMs;
        double b = _actions[i + 1].AtMs;
        float frac = b > a ? (float)Math.Clamp((now - a) / (b - a), 0.0, 1.0) : 0f;
        int pa = ProcessedStrokePos(i, effects);
        int pb = ProcessedStrokePos(i + 1, effects);
        return (int)Math.Round(pa + (pb - pa) * frac);
    }

    // Fan an intensity (0–1) out to every resolved vibe actuator whose source matches.
    private void SendToVibeSource(string source, double intensity)
    {
        if (_vibeRoutes.Count == 0)
            return;
        var bp = _buttplug;
        if (bp == null || !bp.BpConnected)
            return;
        double clamped = Math.Clamp(intensity, 0.0, 1.0);
        foreach (var route in _vibeRoutes)
            if (route.Source == source)
                bp.SendVibrateChannel(route.Index, route.Channel, clamped);
    }

    private static bool HasBlockEffect(Godot.Collections.Array effects)
    {
        foreach (var effectVariant in effects)
        {
            var effect = effectVariant.AsGodotDictionary();
            if (effect.ContainsKey("kind") && effect["kind"].AsString() == "block")
                return true;
        }
        return false;
    }

    // Advances the eased mirror factor toward its target — 1 when an odd number
    // of "reverse" effects are active (even counts cancel), else 0. Driven by the
    // playback clock so the ease freezes with playback and never jumps across a
    // pause; seeks / clock resets snap straight to the target.
    private void UpdateMirrorBlend(Godot.Collections.Array effects) =>
        AdvanceMirror(CountKind(effects, "reverse"), ref _mirrorBlend, ref _mirrorClockMs);

    private void UpdateAxisMirrorBlend(Godot.Collections.Array effects) =>
        AdvanceMirror(CountKind(effects, "axis_reverse"), ref _axisMirrorBlend, ref _axisMirrorClockMs);

    // Moves a mirror blend toward 1 while an odd number of reverses is active (even counts cancel), else
    // toward 0, on the playback clock.
    private void AdvanceMirror(int reverseCount, ref float blend, ref double clockMs)
    {
        float target = (reverseCount % 2 != 0) ? 1f : 0f;

        double dt = double.IsNaN(clockMs) ? 0.0 : _positionMs - clockMs;
        clockMs = _positionMs;
        // A negative or larger-than-ease-window gap is a seek/reset — treat the
        // ease as already elapsed so the blend snaps rather than crawling.
        if (dt < 0.0 || dt > MirrorEaseMs)
            dt = MirrorEaseMs;

        blend = Mathf.MoveToward(blend, target, (float)(dt / MirrorEaseMs));
    }

    private static int CountKind(Godot.Collections.Array effects, string kind)
    {
        int count = 0;
        if (effects == null)
            return 0;
        foreach (var effectVariant in effects)
        {
            var effect = effectVariant.AsGodotDictionary();
            if (effect.ContainsKey("kind") && effect["kind"].AsString() == kind)
                count++;
        }
        return count;
    }

    /// One secondary axis's script position (0–100) with the multi-axis modifiers applied: the eased
    /// reverse first, then every axis_scale multiplied together around centre, then each axis_clamp
    /// remapping into its band — the stroke's own order (TransformPos). The turning axes read the
    /// `rotary_` values where an effect has them. Block is not here: it holds output rather than moving
    /// it (see _PhysicsProcess). Pure — public for the gdUnit suite, like AutoTwistStep.
    public double AxisModifiedPos(string axis, double pos, Godot.Collections.Array effects, double mirrorBlend)
    {
        if (mirrorBlend > 0.0)
            pos += (100.0 - 2.0 * pos) * mirrorBlend;  // toward 100 - pos, through centre at 0.5
        if (effects == null || effects.Count == 0)
            return Math.Clamp(pos, 0.0, 100.0);

        bool rotary = System.Array.IndexOf(RotaryAxes, axis) >= 0;
        double factor = 1.0;
        foreach (var effectVariant in effects)
        {
            var effect = effectVariant.AsGodotDictionary();
            if (effect.ContainsKey("kind") && effect["kind"].AsString() == "axis_scale")
                factor *= AxisParam(effect, "factor", rotary, 1.0);
        }
        // Around centre rather than each stroke's own midpoint: these axes rest at 50 and swing both ways.
        pos = 50.0 + (pos - 50.0) * factor;

        foreach (var effectVariant in effects)
        {
            var effect = effectVariant.AsGodotDictionary();
            if (!effect.ContainsKey("kind") || effect["kind"].AsString() != "axis_clamp")
                continue;
            double min = AxisParam(effect, "min", rotary, 0.0);
            double max = AxisParam(effect, "max", rotary, 100.0);
            pos = min + Math.Clamp(pos, 0.0, 100.0) / 100.0 * (max - min);
        }
        return Math.Clamp(pos, 0.0, 100.0);
    }

    // An axis modifier's value for one axis: the `rotary_` one on a turning axis when the effect has it,
    // else the plain one, else the fallback.
    private static double AxisParam(Godot.Collections.Dictionary effect, string key, bool rotary, double fallback)
    {
        if (rotary && effect.ContainsKey("rotary_" + key))
            return effect["rotary_" + key].AsDouble();
        return effect.ContainsKey(key) ? effect[key].AsDouble() : fallback;
    }

    // Applies the eased mirror flip to a single position (toward 100 - v).
    private float MirrorOne(float v)
    {
        return _mirrorBlend > 0f ? Mathf.Lerp(v, 100f - v, _mirrorBlend) : v;
    }

    // Transforms the action at `index`: mirror, then scale each stroke around its
    // LOCAL centre (the midpoint of its neighbours), then remap into clamp range.
    // Local-centre scaling grows/shrinks each stroke's amplitude in place rather
    // than around a global 50, so strokes near the rails keep their shape instead
    // of being squashed by the 0–100 clamp. Multiple scale effects stack
    // multiplicatively; clamps apply successively. The mirror uses the eased
    // _mirrorBlend so it is never an instant reversal — see UpdateMirrorBlend.
    // Maps a 0–100 script position into the user's device range window by RESCALING
    // (lerp), not hard-clamping — so a stroke keeps its shape and rhythm at reduced
    // amplitude instead of flat-topping/dwelling at the limit. Output is guaranteed
    // within [_rangeMin, _rangeMax] for in-range input; a final Math.Clamp safety
    // net at the send site backstops the ease-from-home blend and any rounding.
    private int RescaleToRange(int pos)
    {
        double n = Math.Clamp(pos, 0, 100) / 100.0;
        return (int)Math.Round(_rangeMin + (_rangeMax - _rangeMin) * n);
    }

    private int TransformPos(int index, Godot.Collections.Array effects)
    {
        float pos = MirrorOne(_actions[index].Pos);

        if (effects == null || effects.Count == 0)
            return (int)Math.Round(Math.Clamp(pos, 0f, 100f));

        // Combined scale factor — all scale effects multiply.
        float scaleFactor = 1f;
        foreach (var effect in effects)
        {
            var effectProp = effect.AsGodotDictionary();
            if (effectProp.ContainsKey("kind") && effectProp["kind"].AsString() == "scale" && effectProp.ContainsKey("factor"))
                scaleFactor *= effectProp["factor"].AsSingle();
        }
        if (!Mathf.IsEqualApprox(scaleFactor, 1f))
        {
            // Scale around the midpoint of the neighbouring points (clamped to the
            // ends), so each stroke's amplitude scales about its own centre.
            float prev = MirrorOne(_actions[Math.Max(0, index - 1)].Pos);
            float next = MirrorOne(_actions[Math.Min(_actions.Count - 1, index + 1)].Pos);
            float center = (prev + next) * 0.5f;
            pos = center + (pos - center) * scaleFactor;
        }

        foreach (var effect in effects)
        {
            var effectProp = effect.AsGodotDictionary();
            if (effectProp.ContainsKey("kind") && effectProp["kind"].AsString() == "clamp")
            {
                float minV = effectProp.ContainsKey("min") ? effectProp["min"].AsSingle() : 0f;
                float maxV = effectProp.ContainsKey("max") ? effectProp["max"].AsSingle() : 100f;
                pos = minV + Math.Clamp(pos, 0f, 100f) / 100f * (maxV - minV);
            }
        }

        return (int)Math.Round(Math.Clamp(pos, 0f, 100f));
    }
}
