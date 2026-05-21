using Godot;
using Buttplug.Client;
using System;

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

	public override async void _Ready()
	{
		var config = new ConfigFile();
		string address = DefaultAddress;
		bool autoConnect = true;

		if (config.Load("user://settings.cfg") == Error.Ok)
		{
			address = (string)config.GetValue("intiface", "address", DefaultAddress);
			autoConnect = (bool)config.GetValue("intiface", "auto_connect", true);
		}

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

		var config = new ConfigFile();
		string selectedName = "";

		if (config.Load("user://settings.cfg") == Error.Ok)
			selectedName = config.GetValue("intiface", "selected_device", Variant.From("")).AsString();

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
		return device != null && device.HasOutput(Buttplug.Core.Messages.OutputType.Position);
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
