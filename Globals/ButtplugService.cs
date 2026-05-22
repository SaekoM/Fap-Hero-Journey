using Godot;
using Buttplug.Client;
using Buttplug.Core.Messages;
using System;
using System.Linq;

public partial class ButtplugService : Node
{
	[Signal] public delegate void ConnectedEventHandler();
	[Signal] public delegate void DisconnectedEventHandler();
	[Signal] public delegate void DeviceAddedEventHandler(string name, int index);
	[Signal] public delegate void DeviceRemovedEventHandler(int index);
	[Signal] public delegate void ScanFinishedEventHandler();
	[Signal] public delegate void ErrorOccurredEventHandler(string message);

	public const string DefaultAddress = "ws://localhost:12345";

	private ButtplugClient _client;

	public bool BpConnected => _client?.Connected ?? false;

	public override void _Ready()
	{
		var settings = GetNode("/root/SettingsService");
		string address = settings.Call("get_intiface_address").AsString();
		bool autoConnect = settings.Call("get_intiface_auto_connect").AsBool();

		if (autoConnect)
			ConnectToIntiface(address);
	}

	public async void ConnectToIntiface(string address)
	{
		if (_client?.Connected == true)
		{
			_client.DeviceAdded -= OnDeviceAdded;
			_client.DeviceRemoved -= OnDeviceRemoved;
			_client.ScanningFinished -= OnScanFinished;
			_client.ServerDisconnect -= OnServerDisconnect;
			await _client.DisconnectAsync();
		}

		try
		{
			_client = new ButtplugClient("Fap Hero Journey");
			_client.DeviceAdded += OnDeviceAdded;
			_client.DeviceRemoved += OnDeviceRemoved;
			_client.ScanningFinished += OnScanFinished;
			_client.ServerDisconnect += OnServerDisconnect;

			var connector = new ButtplugWebsocketConnector(new Uri(address));
			await _client.ConnectAsync(connector);
			Callable.From(() => EmitSignal(SignalName.Connected)).CallDeferred();
		}
		catch (Exception e)
		{
			Callable.From(() => EmitSignal(SignalName.ErrorOccurred, e.Message)).CallDeferred();
		}
	}

	public async void DisconnectFromIntiface()
	{
		if (_client?.Connected != true)
			return;

		try
		{
			await _client.DisconnectAsync();
		}
		catch (Exception e)
		{
			Callable.From(() => EmitSignal(SignalName.ErrorOccurred, e.Message)).CallDeferred();
		}
	}

	// On app quit, disconnect from Intiface. Intiface stops all devices
	// server-side as soon as the controlling client drops, so this guarantees
	// nothing keeps running after the app exits. Best-effort / fire-and-forget —
	// if the process dies first, the closing socket triggers the same stop.
	public override async void _Notification(int what)
	{
		if (what != NotificationWMCloseRequest && what != NotificationExitTree)
			return;

		if (_client?.Connected != true)
			return;

		try
		{
			await _client.DisconnectAsync();
		}
		catch (Exception e)
		{
			GD.PrintErr($"ButtplugService: shutdown disconnect failed: {e.Message}");
		}
	}

	public async void StartScan()
	{
		if (_client?.Connected != true)
			return;

		try
		{
			await _client.StartScanningAsync();
		}
		catch (Exception e)
		{
			Callable.From(() => EmitSignal(SignalName.ErrorOccurred, e.Message)).CallDeferred();
		}
	}

	public Godot.Collections.Array<string> GetDeviceNames()
	{
		var result = new Godot.Collections.Array<string>();

		if (_client == null)
			return result;

		foreach (var device in _client.Devices)
			result.Add(device.Name);

		return result;
	}

	public int GetSelectedDeviceIndex()
	{
		if (_client == null || !_client.Connected)
			return -1;

		string selectedName = GetNode("/root/SettingsService").Call("get_selected_device").AsString();

		if (!string.IsNullOrEmpty(selectedName))
		{
			foreach (var device in _client.Devices)
				if (device.Name == selectedName)
					return (int)device.Index;
		}

		// Fallback: first available device
		foreach (var device in _client.Devices)
			return (int)device.Index;

		return -1;
	}

	public bool DeviceSupportsLinear(int deviceIndex)
	{
		var device = GetDeviceAt(deviceIndex);
		return device != null && device.HasOutput(OutputType.Position);
	}

	// Returns the number of independent vibration channels (actuators) on the device.
	// Most single-motor devices return 1; dual-motor devices (e.g. We-Vibe Sync,
	// Lovense Nora/Max 2) return 2.
	public int GetVibrationChannelCount(int deviceIndex)
	{
		var device = GetDeviceAt(deviceIndex);
		if (device == null)
			return 0;

		try 
		{ 
			return device.GetFeaturesWithOutput(OutputType.Vibrate).Count(); 
		}
		catch 
		{ 
			return 1; 
		}
	}

	// Send a vibration command to a specific actuator channel by its index.
	// Channel 0 = primary motor, channel 1 = secondary motor.
	// Falls back to all-channels if the index is out of range.
	public async void SendVibrateChannel(int deviceIndex, int channelIndex, double intensity)
	{
		var device = GetDeviceAt(deviceIndex);
		if (device == null) 
			return;

		try
		{
			// ElementAtOrDefault avoids the per-call List allocation that .ToList()
			// would incur — this runs once per vib action, many times a second.
			var feature = device.GetFeaturesWithOutput(OutputType.Vibrate).ElementAtOrDefault(channelIndex);
			if (feature == null)
			{
				// Index out of range (or negative) — fall back to all-channels.
				await device.RunOutputAsync(DeviceOutput.Vibrate.Percent(intensity), default);
				return;
			}

			await feature.RunOutputAsync(DeviceOutput.Vibrate.Percent(intensity), default);
		}
		catch (Exception e)
		{
			GD.PrintErr($"ButtplugService: SendVibrateChannel failed: {e.Message}");
		}
	}

	public async void SendVibrate(int deviceIndex, double intensity)
	{
		var device = GetDeviceAt(deviceIndex);
		if (device == null)
			return;

		try
		{
			await device.RunOutputAsync(DeviceOutput.Vibrate.Percent(intensity));
		}
		catch (Exception e)
		{
			GD.PrintErr($"ButtplugService: SendVibrate failed: {e.Message}");
		}
	}

	public async void SendLinear(int deviceIndex, uint durationMs, double position)
	{
		var device = GetDeviceAt(deviceIndex);
		if (device == null)
			return;

		try
		{
			await device.RunOutputAsync(DeviceOutput.PositionWithDuration.Percent(position, durationMs));
		}
		catch (Exception e)
		{
			GD.PrintErr($"ButtplugService: SendLinear failed: {e.Message}");
		}
	}

	private ButtplugClientDevice GetDeviceAt(int deviceIndex)
	{
		if (_client == null || !_client.Connected) 
			return null;

		foreach (var device in _client.Devices)
			if ((int)device.Index == deviceIndex) 
				return device;

		return null;
	}

	private void OnDeviceAdded(object sender, DeviceAddedEventArgs e)
	{
		string name = e.Device.Name;
		int idx = (int)e.Device.Index;
		Callable.From(() => EmitSignal(SignalName.DeviceAdded, name, idx)).CallDeferred();
	}

	private void OnDeviceRemoved(object sender, DeviceRemovedEventArgs e)
	{
		int idx = (int)e.Device.Index;
		Callable.From(() => EmitSignal(SignalName.DeviceRemoved, idx)).CallDeferred();
	}

	private void OnScanFinished(object sender, EventArgs e)
	{
		Callable.From(() => EmitSignal(SignalName.ScanFinished)).CallDeferred();
	}

	private void OnServerDisconnect(object sender, EventArgs e)
	{
		Callable.From(() => EmitSignal(SignalName.Disconnected)).CallDeferred();
	}
}
