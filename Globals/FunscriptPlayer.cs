using Godot;
using Godot.Collections;
using System;
using System.Collections.Generic;

public partial class FunscriptPlayer : Node
{
	private struct Action { public float AtMs; public int Pos; }

	private enum OutputMode { Buttplug, Serial }

	private List<Action> _actions = new List<Action>();
	private bool _playing = false;
	private double _positionMs = 0.0;
	private int _actionIndex = 0;
	private bool? _isLinearDevice = null;
	private int _deviceIndex = -1;
	private bool _syncedThisFrame = false;
	private OutputMode _outputMode = OutputMode.Buttplug;
	private bool _outputResolved = false;
	private int _rangeMin = 0;
	private int _rangeMax = 100;

	public bool Playing     => _playing;
	public int  ActionCount => _actions.Count;

	public void LoadFunscript(string path)
	{
		_actions.Clear();
		_actionIndex = 0;
		_positionMs = 0.0;
		_playing = false;
		_isLinearDevice = null;

		string absPath = ProjectSettings.GlobalizePath(path);
		using var f = FileAccess.Open(absPath, FileAccess.ModeFlags.Read);
		if (f == null) 
		{ 
			GD.PrintErr($"FunscriptPlayer: cannot open {path}"); 
			return; 
		}

		var parser = new Json();
		if (parser.Parse(f.GetAsText()) != Error.Ok)
		{
			GD.PrintErr($"FunscriptPlayer: JSON parse error in {path}");
			return;
		}

		var data = parser.Data.AsGodotDictionary();
		var raw = data.ContainsKey("actions") ? data["actions"].AsGodotArray() : new Godot.Collections.Array();
		foreach (var item in raw)
		{
			var a = item.AsGodotDictionary();
			_actions.Add(new Action
			{
				AtMs = a.ContainsKey("at") ? a["at"].AsSingle() : 0f,
				Pos = a.ContainsKey("pos") ? a["pos"].AsInt32() : 0,
			});
		}
	}

	private const uint EaseDurationMs = 500;
	private const double CenterPosition = 0.5;

	public void Play() => _playing = true;

	public void Pause()
	{
		_playing = false;
		EaseToNeutral();
	}

	public void Resume() => _playing = true;

	public void Stop()
	{
		_playing = false;
		EaseToNeutral();
		_positionMs = 0.0;
		_actionIndex = 0;
		_isLinearDevice = null;
		_deviceIndex = -1;
		_outputResolved = false;
	}

	// Send a gentle "go to neutral" command so the device doesn't stay
	// mid-stroke or vibrating when playback halts. Linear → midpoint,
	// vibrator → 0 intensity. Safe to call when nothing is connected.
	private void EaseToNeutral()
	{
		ResolveOutput();

		if (_outputMode == OutputMode.Serial)
		{
			var serial = GetNode<SerialDeviceService>("/root/SerialDeviceService");
			if (serial != null && serial.SerialConnected)
				serial.SendLinear(EaseDurationMs, CenterPosition);
			return;
		}

		var bp = GetNode<ButtplugService>("/root/ButtplugService");
		if (bp == null || !bp.BpConnected || _deviceIndex < 0)
			return;

		if (_isLinearDevice == true)
			bp.SendLinear(_deviceIndex, EaseDurationMs, CenterPosition);
		else
			bp.SendVibrate(_deviceIndex, 0.0);
	}

	// Call this each frame from GameLoop to keep funscript in sync with the video clock.
	// Only updates _positionMs — _Process is responsible for dispatching due actions.
	public void SyncTo(double videoPositionSec)
	{
		_positionMs = videoPositionSec * 1000.0;
		_syncedThisFrame = true;
	}

	public override void _Process(double delta)
	{
		if (!_playing || _actions.Count == 0)
			return;

		// When synced to a video clock, SyncTo already set _positionMs this frame.
		// Only accumulate delta in free-running mode (no video / funscript-only).
		if (_syncedThisFrame)
			_syncedThisFrame = false;
		else
			_positionMs += delta * 1000.0;

		while (_actionIndex < _actions.Count)
		{
			if (_actions[_actionIndex].AtMs > _positionMs)
				break;

			SendCommand(_actionIndex);
			_actionIndex++;
		}

	}

	private void ResolveOutput()
	{
		if (_outputResolved) 
			return;

		var config = new ConfigFile();
		if (config.Load("user://settings.cfg") == Error.Ok)
		{
			string mode = config.GetValue("output", "mode", Variant.From("buttplug")).AsString();
			_outputMode = mode == "serial" ? OutputMode.Serial : OutputMode.Buttplug;

			// Cache device range limits so SendCommand doesn't hit disk per-action.
			_rangeMin = (int)config.GetValue("device", "range_min", Variant.From(0)).AsSingle();
			_rangeMax = (int)config.GetValue("device", "range_max", Variant.From(100)).AsSingle();
		}

		if (_outputMode == OutputMode.Serial)
		{
			// Serial T-code devices are always linear; nothing else to resolve.
			_isLinearDevice = true;
			_deviceIndex = 0;
		}
		else
		{
			var bp = GetNode<ButtplugService>("/root/ButtplugService");
			if (bp != null)
			{
				_deviceIndex = bp.GetSelectedDeviceIndex();
				_isLinearDevice = _deviceIndex >= 0 && bp.DeviceSupportsLinear(_deviceIndex);
			}
		}
		_outputResolved = true;
	}

	private void SendCommand(int index)
	{
		ResolveOutput();

		var inv = GetNodeOrNull<InventoryService>("/root/InventoryService");
		var effects = inv?.GetActiveEffects();

		if (effects != null && HasBlockEffect(effects))
			return;

		int currentPos = TransformPos(_actions[index].Pos, effects);
		int nextPos    = index + 1 < _actions.Count ? TransformPos(_actions[index + 1].Pos, effects) : currentPos;

		// Apply user-configured hard range clamp (device settings → Position Clamp).
		// Runs after inventory effects so shop modifiers compose correctly with the limit.
		currentPos = Math.Clamp(currentPos, _rangeMin, _rangeMax);
		nextPos    = Math.Clamp(nextPos,    _rangeMin, _rangeMax);

		if (index + 1 < _actions.Count)
		{
			int amplitude = Math.Abs(nextPos - currentPos);
			GetNode<ScoreService>("/root/ScoreService")?.AddStroke(amplitude);
		}

		if (_outputMode == OutputMode.Serial)
		{
			var serial = GetNode<SerialDeviceService>("/root/SerialDeviceService");

			if (serial == null || !serial.SerialConnected)
				return;

			if (index + 1 >= _actions.Count)
				return;

			double targetNormalised = nextPos / 100.0;
			uint durationMs = (uint)Math.Max(1, (int)(_actions[index + 1].AtMs - _actions[index].AtMs));
			serial.SendLinear(durationMs, targetNormalised);

			return;
		}

		var bp = GetNode<ButtplugService>("/root/ButtplugService");
		if (bp == null || !bp.BpConnected || _deviceIndex < 0)
			return;

		if (_isLinearDevice == true)
		{
			if (index + 1 >= _actions.Count)
				return;

			double targetNormalised = nextPos / 100.0;
			uint durationMs = (uint)Math.Max(1, (int)(_actions[index + 1].AtMs - _actions[index].AtMs));
			bp.SendLinear(_deviceIndex, durationMs, targetNormalised);
		}
		else
		{
			// Vibrators have no stroke direction — just hold the current keyframe intensity.
			bp.SendVibrate(_deviceIndex, currentPos / 100.0);
		}
	}

	private static bool HasBlockEffect(Godot.Collections.Array effects)
	{
		foreach (var e in effects)
		{
			var d = e.AsGodotDictionary();
			if (d.ContainsKey("kind") && d["kind"].AsString() == "block")
				return true;
		}
		return false;
	}

	// Scale around centre, then remap into clamp range. Multiple effects of the
	// same kind stack multiplicatively (scale) or successively (clamp).
	private static int TransformPos(int rawPos, Godot.Collections.Array effects)
	{
		if (effects == null || effects.Count == 0) return rawPos;
		float pos = rawPos;
		foreach (var e in effects)
		{
			var d = e.AsGodotDictionary();
			if (d.ContainsKey("kind") && d["kind"].AsString() == "scale" && d.ContainsKey("factor"))
			{
				float factor = d["factor"].AsSingle();
				pos = 50f + (pos - 50f) * factor;
			}
		}
		foreach (var e in effects)
		{
			var d = e.AsGodotDictionary();
			if (d.ContainsKey("kind") && d["kind"].AsString() == "clamp")
			{
				float minV = d.ContainsKey("min") ? d["min"].AsSingle() : 0f;
				float maxV = d.ContainsKey("max") ? d["max"].AsSingle() : 100f;
				pos = minV + Math.Clamp(pos, 0f, 100f) / 100f * (maxV - minV);
			}
		}
		pos = Math.Clamp(pos, 0f, 100f);
		return (int)Math.Round(pos);
	}
}
