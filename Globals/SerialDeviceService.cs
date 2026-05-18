using Godot;
using System;
using System.IO.Ports;

// Direct serial output for T-code devices (SR6, OSR2, etc.).
// Bypasses Buttplug/Intiface — talks T-code v0.3 over a COM port.
// Format: L0XXXXIDDDD\n  — linear axis 0, position 0-9999, interpolate over DDDD ms.
public partial class SerialDeviceService : Node
{
	[Signal] public delegate void ConnectedEventHandler();
	[Signal] public delegate void DisconnectedEventHandler();
	[Signal] public delegate void ErrorOccurredEventHandler(string message);

	public const int DefaultBaudRate = 115200;

	private SerialPort _port;

	public bool SerialConnected => _port?.IsOpen ?? false;
	public string ConnectedPortName => _port?.PortName ?? "";

	public override void _Ready()
	{
		var config = new ConfigFile();
		if (config.Load("user://settings.cfg") != Error.Ok)
			return;

		bool autoConnect = (bool)config.GetValue("serial", "auto_connect", false);
		if (!autoConnect)
			return;

		string portName = config.GetValue("serial", "port", Variant.From("")).AsString();
		int baud = (int)config.GetValue("serial", "baud_rate", DefaultBaudRate);
		if (!string.IsNullOrEmpty(portName))
			Connect(portName, baud);
	}

	public Godot.Collections.Array<string> GetAvailablePorts()
	{
		var result = new Godot.Collections.Array<string>();
		foreach (var p in SerialPort.GetPortNames())
			result.Add(p);
		return result;
	}

	public bool Connect(string portName, int baudRate = DefaultBaudRate)
	{
		Disconnect();
		try
		{
			_port = new SerialPort(portName, baudRate)
			{
				NewLine = "\n",
				WriteTimeout = 100,
				ReadTimeout  = 100,
				DtrEnable    = true,
				RtsEnable    = true,
			};

			_port.Open();

			Callable.From(() => EmitSignal(SignalName.Connected)).CallDeferred();

			return true;
		}
		catch (Exception e)
		{
			_port = null;
			Callable.From(() => EmitSignal(SignalName.ErrorOccurred, e.Message)).CallDeferred();
			return false;
		}
	}

	public void Disconnect()
	{
		if (_port == null)
			return;
		try
		{
			if (_port.IsOpen)
				_port.Close();
		}
		catch (Exception e)
		{
			GD.PrintErr($"SerialDeviceService: error closing port: {e.Message}");
		}
		_port = null;
		Callable.From(() => EmitSignal(SignalName.Disconnected)).CallDeferred();
	}

	// position: 0.0-1.0, durationMs: how long the device should take to reach the target.
	public void SendLinear(uint durationMs, double position)
	{
		if (!SerialConnected) 
			return;

		int posInt = Math.Clamp((int)Math.Round(position * 9999.0), 0, 9999);
		TryWrite($"L0{posInt:D4}I{durationMs}\n");
	}

	// Vibration channel V0 (T-code v0.3). intensity: 0.0-1.0.
	public void SendVibrate(double intensity)
	{
		if (!SerialConnected) 
			return;

		int level = Math.Clamp((int)Math.Round(intensity * 9999.0), 0, 9999);
		TryWrite($"V0{level:D4}\n");
	}

	// Immediately stop all axes.
	public void StopAll()
	{
		if (!SerialConnected) return;
		TryWrite("DSTOP\n");
	}

	private void TryWrite(string cmd)
	{
		try
		{
			_port.Write(cmd);
		}
		catch (Exception e)
		{
			GD.PrintErr($"SerialDeviceService: write failed: {e.Message}");
			Disconnect();
		}
	}
}
