using Godot;
using Buttplug.Client;
using Buttplug.Core.Messages;
using System;
using System.Linq;
using System.Threading.Tasks;

public partial class ButtplugService : Node
{
    [Signal] public delegate void ConnectedEventHandler();
    [Signal] public delegate void DisconnectedEventHandler();
    [Signal] public delegate void DeviceAddedEventHandler(string name, int index);
    [Signal] public delegate void DeviceRemovedEventHandler(int index);
    [Signal] public delegate void ScanFinishedEventHandler();
    [Signal] public delegate void ErrorOccurredEventHandler(string message);

    public const string DefaultAddress = "ws://localhost:12345";

    // How long to wait for the connect + Buttplug handshake before giving up. On
    // some machines the handshake stalls (the websocket opens but RequestServerInfo
    // never completes); the timeout turns that into a clear error + clean retry
    // instead of a silent hang that Intiface eventually drops on its keepalive.
    private const int ConnectTimeoutMs = 10000;

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
        // Tear down any previous client first so a retry always starts clean. Do
        // NOT await DisconnectAsync on a possibly half-dead socket (it can hang) —
        // unsubscribe, fire-and-forget the disconnect, and drop the reference. While
        // _client is null the other methods (StartScan / SendLinear / …) no-op safely.
        if (_client != null)
        {
            var old = _client;
            _client = null;
            old.DeviceAdded -= OnDeviceAdded;
            old.DeviceRemoved -= OnDeviceRemoved;
            old.ScanningFinished -= OnScanFinished;
            old.ServerDisconnect -= OnServerDisconnect;
            try { _ = old.DisconnectAsync(); } catch { /* best effort */ }
        }

        var client = new ButtplugClient("Fap Hero Journey");
        client.DeviceAdded += OnDeviceAdded;
        client.DeviceRemoved += OnDeviceRemoved;
        client.ScanningFinished += OnScanFinished;
        client.ServerDisconnect += OnServerDisconnect;

        try
        {
            var connector = new ButtplugWebsocketConnector(new Uri(address));
            // Run the connect + handshake on a thread-pool thread so it never depends
            // on Godot's main-thread SynchronizationContext pumping continuations —
            // that stall is what hangs the handshake (websocket opens but
            // RequestServerInfo never sends) on some machines. WaitAsync enforces the
            // timeout so a stall surfaces as an error rather than hanging forever.
            // ConfigureAwait(false): resume the continuation off the Godot context too,
            // so even setting _client / emitting the signal never waits on the main
            // thread. EmitSignal is marshalled back via CallDeferred (thread-safe).
            await Task.Run(() => client.ConnectAsync(connector))
                .WaitAsync(TimeSpan.FromMilliseconds(ConnectTimeoutMs))
                .ConfigureAwait(false);

            _client = client;
            Callable.From(() => EmitSignal(SignalName.Connected)).CallDeferred();
        }
        catch (TimeoutException)
        {
            _CleanupFailedClient(client);
            Callable.From(() => EmitSignal(SignalName.ErrorOccurred,
                "Connection timed out — Intiface accepted the connection but the handshake didn't finish. Try Connect again, or restart Intiface.")).CallDeferred();
        }
        catch (Exception e)
        {
            _CleanupFailedClient(client);
            Callable.From(() => EmitSignal(SignalName.ErrorOccurred, e.Message)).CallDeferred();
        }
    }

    // Unhooks and disposes a client that failed to connect, so a retry isn't left
    // fighting a half-open socket / orphaned receive loop.
    private void _CleanupFailedClient(ButtplugClient client)
    {
        client.DeviceAdded -= OnDeviceAdded;
        client.DeviceRemoved -= OnDeviceRemoved;
        client.ScanningFinished -= OnScanFinished;
        client.ServerDisconnect -= OnServerDisconnect;
        try { _ = client.DisconnectAsync(); } catch { /* best effort */ }
        if (_client == client)
            _client = null;
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

    // Returns the Name of whichever device GetSelectedDeviceIndex would
    // currently route commands to (the user's selection if present, otherwise
    // the fallback). Empty string when no device is available. Used by the
    // GameLoop disconnect banner to detect "selected device unavailable, using
    // a fallback instead" and tell the user about the mismatch.
    public string GetActiveDeviceName()
    {
        int idx = GetSelectedDeviceIndex();
        if (idx < 0)
            return "";
        foreach (var device in _client.Devices)
            if ((int)device.Index == idx)
                return device.Name;
        return "";
    }

    // BP-local stable id for a device: "<name>#<occurrence>" (occurrence = 0-based ordinal among
    // identically-named devices, in enumeration order). Matches the ids the routing config and the
    // DeviceRouting resolver use.
    private static string MakeDeviceId(string name, int occurrence)
    {
        return $"{name}#{occurrence}";
    }

    // Connected Buttplug devices with the capability info the route resolver + Options mapping UI need.
    // Each entry matches DeviceRouting's catalog contract plus the live `index` (used by dispatch):
    //   { id, index, name, linear, vibrate_channels, constrict_channels }
    // Empty when not connected.
    public Godot.Collections.Array GetDeviceCatalog()
    {
        var result = new Godot.Collections.Array();
        if (_client == null || !_client.Connected)
            return result;

        var nameCounts = new System.Collections.Generic.Dictionary<string, int>();
        foreach (var device in _client.Devices)
        {
            int occurrence = nameCounts.TryGetValue(device.Name, out int seen) ? seen : 0;
            nameCounts[device.Name] = occurrence + 1;
            int deviceIndex = (int)device.Index;

            result.Add(new Godot.Collections.Dictionary
            {
                ["id"] = MakeDeviceId(device.Name, occurrence),
                ["index"] = deviceIndex,
                ["name"] = device.Name,
                ["linear"] = DeviceSupportsLinear(deviceIndex),
                ["vibrate_channels"] = GetVibrationChannelCount(deviceIndex),
                ["constrict_channels"] = GetConstrictChannelCount(deviceIndex),
                ["oscillate_channels"] = GetOscillateChannelCount(deviceIndex),
            });
        }
        return result;
    }

    // Resolve a BP-local device id ("<name>#<occurrence>", or a bare "<name>" = occurrence 0) to its
    // live device index, or -1 if not currently connected. A leading "bp:" prefix is tolerated so the
    // routing layer can pass a namespaced id straight through.
    public int GetDeviceIndexById(string deviceId)
    {
        if (_client == null || !_client.Connected || string.IsNullOrEmpty(deviceId))
            return -1;
        if (deviceId.StartsWith("bp:"))
            deviceId = deviceId.Substring(3);

        var nameCounts = new System.Collections.Generic.Dictionary<string, int>();
        foreach (var device in _client.Devices)
        {
            int occurrence = nameCounts.TryGetValue(device.Name, out int seen) ? seen : 0;
            nameCounts[device.Name] = occurrence + 1;
            if (MakeDeviceId(device.Name, occurrence) == deviceId || (occurrence == 0 && device.Name == deviceId))
                return (int)device.Index;
        }
        return -1;
    }

    // Treats a device as "linear" (a stroker) if it advertises either of the two
    // linear output types in Buttplug.Core.Messages.OutputType:
    //   • HwPositionWithDuration — the classic LinearCmd (target + duration).
    //     Used by The Handy, OSR2/SR6 via Intiface, Kiiroo Keon, and basically
    //     every funscript-driven stroker in the wild.
    //   • Position — newer "go to absolute position immediately" command used by
    //     a small number of next-gen devices.
    // Checking only `Position` used to drop the Handy onto the vibrator code
    // path, so SendVibrate was sent to a device with no vibrate actuator and
    // playback was silently dropped.
    public bool DeviceSupportsLinear(int deviceIndex)
    {
        var device = GetDeviceAt(deviceIndex);
        return device != null && (
            device.HasOutput(OutputType.HwPositionWithDuration) ||
            device.HasOutput(OutputType.Position)
        );
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

    // Number of independent constrict (pneumatic squeeze) actuators on the device.
    // 0 for devices without a constrict feature (the common case).
    public int GetConstrictChannelCount(int deviceIndex)
    {
        var device = GetDeviceAt(deviceIndex);
        if (device == null)
            return 0;

        try
        {
            return device.GetFeaturesWithOutput(OutputType.Constrict).Count();
        }
        catch
        {
            return 0;
        }
    }

    // Number of oscillate actuators on the device: speed-driven outputs such as a thrusting machine's
    // motor. 0 for everything else (the common case).
    public int GetOscillateChannelCount(int deviceIndex)
    {
        var device = GetDeviceAt(deviceIndex);
        if (device == null)
            return 0;

        try
        {
            return device.GetFeaturesWithOutput(OutputType.Oscillate).Count();
        }
        catch
        {
            return 0;
        }
    }

    // Run an oscillate actuator at `speed` (0–1; 0 stops it). Channel 0 = the primary oscillator. Unlike
    // vibrate there is no all-channels fallback: an out-of-range channel sends nothing, since starting a
    // machine's other motor by mistake is worse than not starting one.
    public async void SendOscillateChannel(int deviceIndex, int channelIndex, double speed)
    {
        var device = GetDeviceAt(deviceIndex);
        if (device == null)
            return;

        try
        {
            var feature = device.GetFeaturesWithOutput(OutputType.Oscillate).ElementAtOrDefault(channelIndex);
            if (feature == null)
                return;
            await feature.RunOutputAsync(DeviceOutput.Oscillate.Percent(Math.Clamp(speed, 0.0, 1.0)), default);
        }
        catch (Exception e)
        {
            GD.PrintErr($"ButtplugService: SendOscillateChannel failed: {e.Message}");
        }
    }

    // Inclusive maximum step a constrict feature accepts. Callers drive discrete levels
    // (0/1/2); this caps an unsupported level before it reaches the device.
    public int GetConstrictMaxStep(int deviceIndex, int channelIndex)
    {
        var device = GetDeviceAt(deviceIndex);
        if (device == null)
            return 0;

        try
        {
            var feature = device.GetFeaturesWithOutput(OutputType.Constrict).ElementAtOrDefault(channelIndex);
            if (feature != null && feature.TryGetOutputRange(OutputType.Constrict, out int min, out int max))
                return Math.Max(min, max);
        }
        catch { }

        return 0;
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

    // Set a constrict (pneumatic squeeze) actuator to a discrete level. Unlike vibration this is
    // state-based — it receives transitions, not a per-keyframe stream. The level is clamped to the
    // feature's reported range. Channel 0 = primary constrict actuator.
    public async void SendConstrictLevel(int deviceIndex, int channelIndex, int level)
    {
        var device = GetDeviceAt(deviceIndex);
        if (device == null)
            return;

        try
        {
            var feature = device.GetFeaturesWithOutput(OutputType.Constrict).ElementAtOrDefault(channelIndex);
            if (feature == null)
                return;

            if (feature.TryGetOutputRange(OutputType.Constrict, out int min, out int max))
                level = Math.Clamp(level, min, max);
            else
                level = Math.Max(0, level);

            await feature.RunOutputAsync(DeviceOutput.Constrict.Steps(level), default);
        }
        catch (Exception e)
        {
            GD.PrintErr($"ButtplugService: SendConstrictLevel failed: {e.Message}");
        }
    }

    public async void SendLinear(int deviceIndex, uint durationMs, double position)
    {
        var device = GetDeviceAt(deviceIndex);
        if (device == null)
            return;

        try
        {
            // Pick the command from what the device actually supports. Some devices advertise Position
            // but reject PositionWithDuration (OutputCmd MessageNotSupported), so sending the wrong one
            // throws — prefer the classic LinearCmd, fall back to immediate Position.
            if (device.HasOutput(OutputType.HwPositionWithDuration))
                await device.RunOutputAsync(DeviceOutput.PositionWithDuration.Percent(position, durationMs));
            else if (device.HasOutput(OutputType.Position))
                await device.RunOutputAsync(DeviceOutput.Position.Percent(position));
            else
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
        string deviceName = e.Device.Name;
        int deviceIndex = (int)e.Device.Index;
        Callable.From(() => EmitSignal(SignalName.DeviceAdded, deviceName, deviceIndex)).CallDeferred();
    }

    private void OnDeviceRemoved(object sender, DeviceRemovedEventArgs e)
    {
        int deviceIndex = (int)e.Device.Index;
        Callable.From(() => EmitSignal(SignalName.DeviceRemoved, deviceIndex)).CallDeferred();
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
