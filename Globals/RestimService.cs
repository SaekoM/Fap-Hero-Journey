using Godot;
using System;
using System.Collections.Generic;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

// Network T-code output to a running restim instance (e-stim).
// restim exposes a WebSocket T-code endpoint (default ws://127.0.0.1:12346/tcode)
// that accepts plain-text frames of whitespace-separated T-code commands, e.g.
// "L05000I100" or "L05000 V02000". This service is a thin WebSocket client that
// formats the game's normalized 0-1 axis values as T-code and streams them there.
//
// Wire format matches SerialDeviceService and the "E-Stim Full" profile's
// OutputPrecision:4 — "AABBBB[ICCCC]": 2-char axis id, 4-digit value (value/10000),
// optional interval in ms. restim clamps the value to 0-1 and remaps to the target range.
//
// The mapping from game funscript slots to restim axes (baked from MultiFunPlayer's
// "E-Stim Full" device profile) lives in the static members below; FunscriptPlayer
// owns the routing policy and calls SendTCode / SendBatch.
public partial class RestimService : Node
{
    [Signal] public delegate void ConnectedEventHandler();
    [Signal] public delegate void DisconnectedEventHandler();
    [Signal] public delegate void ErrorOccurredEventHandler(string message);

    public const string DefaultServer = "ws://127.0.0.1:12346";
    public const string DefaultPath = "/tcode";

    private const int ConnectTimeoutMs = 8000;
    // Bounded so a stalled socket can't grow the queue without bound; oldest frames
    // are dropped under backpressure (a skipped realtime update is harmless).
    private const int SendQueueCapacity = 256;

    // ── E-Stim Full axis map (from MultiFunPlayer.config.json) ──────────────────
    // Primary stroke → restim Alpha (position).
    public const string StrokeAxis = "L0";

    // Game secondary T-code axis (as keyed in FunscriptPlayer._axes) → restim axis.
    //   L1 surge → L1 (Beta) · R0 twist → C0 (carrier) · R2 pitch → P0 (pulse freq)
    //   L2 sway  → V1 (vib1 freq) · R1 roll → V2 (vib1 strength)
    // (surge maps to L1 only — P1/pulse-width is a manual-only axis by design.)
    public static readonly System.Collections.Generic.Dictionary<string, string> MotionAxisMap =
        new System.Collections.Generic.Dictionary<string, string>
        {
            { "L1", "L1" },
            { "R0", "C0" },
            { "R2", "P0" },
            { "L2", "V1" },
            { "R1", "V2" },
        };

    // All 18 "E-Stim Full" axes, in a stable display/stream order. The first six are
    // the motion-capable axes (driven live by funscripts when present, else by their
    // manual value); the rest are manual-only.
    public static readonly string[] AllAxes =
    {
        "L0", "L1", "C0", "P0", "V1", "V2",
        "V0", "P1", "P2", "P3", "V3", "V4", "V5", "V6", "V7", "V8", "V9", "W1",
    };

    private ClientWebSocket _ws;
    private CancellationTokenSource _cts;
    private Channel<string> _sendChannel;

    // Open state. Reads are lock-free; _ws is only replaced under the connect/disconnect flow.
    // Named RestimConnected (not Connected) to avoid clashing with the generated Connected signal.
    public bool RestimConnected => _ws != null && _ws.State == WebSocketState.Open;

    public override void _Ready()
    {
        var settings = GetNode("/root/SettingsService");
        if (!settings.Call("get_restim_auto_connect").AsBool())
            return;
        string server = settings.Call("get_restim_server").AsString();
        string path = settings.Call("get_restim_path").AsString();
        Connect(BuildAddress(server, path));
    }

    // Build the full ws:// URI from a server ("ws://host:port") and a path ("/tcode").
    // Kept here so callers (Options) and defaults agree on how the two fields combine.
    public static string BuildAddress(string server, string path)
    {
        server = (server ?? "").Trim().TrimEnd('/');
        path = (path ?? "").Trim();
        if (path.Length > 0 && !path.StartsWith("/"))
            path = "/" + path;
        return server + path;
    }

    public async void Connect(string address)
    {
        // Tear down any previous socket first so a retry starts clean.
        Disconnect();

        var ws = new ClientWebSocket();
        Uri uri;
        try
        {
            uri = new Uri(address);
        }
        catch (Exception e)
        {
            ws.Dispose();
            _EmitError($"Invalid restim address '{address}': {e.Message}");
            return;
        }

        try
        {
            using var connectCts = new CancellationTokenSource(ConnectTimeoutMs);
            await ws.ConnectAsync(uri, connectCts.Token).ConfigureAwait(false);

            _ws = ws;
            _cts = new CancellationTokenSource();
            _sendChannel = Channel.CreateBounded<string>(new BoundedChannelOptions(SendQueueCapacity)
            {
                FullMode = BoundedChannelFullMode.DropOldest,
                SingleReader = true,
            });

            _ = Task.Run(() => SendLoop(_ws, _sendChannel, _cts.Token));
            _ = Task.Run(() => ReceiveLoop(_ws, _cts.Token));

            // Turn off the serial T-code device (both are T-code sinks; restim replaces it)
            // and announce the connection — both on the main thread.
            Callable.From(() =>
            {
                var serial = GetNodeOrNull<SerialDeviceService>("/root/SerialDeviceService");
                serial?.Disconnect();
                EmitSignal(SignalName.Connected);
            }).CallDeferred();
        }
        catch (OperationCanceledException)
        {
            ws.Dispose();
            _EmitError("restim connection timed out — is restim running and its WebSocket server enabled?");
        }
        catch (Exception e)
        {
            ws.Dispose();
            _EmitError($"restim connection failed: {e.Message}");
        }
    }

    public void Disconnect()
    {
        var ws = _ws;
        var cts = _cts;
        var chan = _sendChannel;
        _ws = null;
        _cts = null;
        _sendChannel = null;

        if (ws == null)
            return;

        chan?.Writer.TryComplete();
        try { cts?.Cancel(); } catch { /* best effort */ }
        try { _ = ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None); } catch { }
        try { cts?.Dispose(); } catch { }
        // ws is disposed by the send/receive loops when they observe cancellation/close.
        try { ws.Dispose(); } catch { }

        Callable.From(() => EmitSignal(SignalName.Disconnected)).CallDeferred();
    }

    // Queue a single T-code command. value01 is 0-1; intervalMs>0 adds an "I" interpolation hint.
    public void SendTCode(string axis, double value01, uint intervalMs = 0)
    {
        var chan = _sendChannel;
        if (chan == null)
            return;
        chan.Writer.TryWrite(FormatCommand(axis, value01, intervalMs));
    }

    // Queue several commands as ONE space-separated frame (fewer WS sends per game frame).
    public void SendBatch(IEnumerable<(string axis, double value01, uint intervalMs)> commands)
    {
        var chan = _sendChannel;
        if (chan == null)
            return;

        var sb = new StringBuilder();
        foreach (var (axis, value01, intervalMs) in commands)
        {
            if (sb.Length > 0)
                sb.Append(' ');
            sb.Append(FormatCommand(axis, value01, intervalMs));
        }
        if (sb.Length > 0)
            chan.Writer.TryWrite(sb.ToString());
    }

    // "AABBBB[ICCCC]" — 4-digit value (matches OutputPrecision:4 and SerialDeviceService).
    private static string FormatCommand(string axis, double value01, uint intervalMs)
    {
        int ticks = Math.Clamp((int)Math.Round(value01 * 9999.0), 0, 9999);
        return intervalMs > 0
            ? $"{axis}{ticks:D4}I{intervalMs}"
            : $"{axis}{ticks:D4}";
    }

    // Drains the send channel and writes each frame to the socket in order. One reader,
    // so ClientWebSocket.SendAsync is never called concurrently. Any failure disconnects.
    private async Task SendLoop(ClientWebSocket ws, Channel<string> chan, CancellationToken token)
    {
        try
        {
            while (await chan.Reader.WaitToReadAsync(token).ConfigureAwait(false))
            {
                while (chan.Reader.TryRead(out string msg))
                {
                    var bytes = Encoding.ASCII.GetBytes(msg);
                    await ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, token)
                        .ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) { /* normal on disconnect */ }
        catch (Exception e)
        {
            _OnLoopFailure(ws, $"restim send failed: {e.Message}");
        }
    }

    // restim's /tcode endpoint is send-only from our side, but we must keep reading so the
    // socket detects a server-side close. Incoming data is discarded.
    private async Task ReceiveLoop(ClientWebSocket ws, CancellationToken token)
    {
        var buffer = new byte[1024];
        try
        {
            while (!token.IsCancellationRequested && ws.State == WebSocketState.Open)
            {
                var result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), token).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    _OnLoopFailure(ws, null);
                    return;
                }
            }
        }
        catch (OperationCanceledException) { /* normal on disconnect */ }
        catch (Exception e)
        {
            _OnLoopFailure(ws, $"restim connection lost: {e.Message}");
        }
    }

    // A loop observed the socket die. If this is still the active socket, drop it and
    // notify — guarded so send+receive both failing only reports once.
    private void _OnLoopFailure(ClientWebSocket ws, string message)
    {
        if (_ws != ws)
            return; // already replaced/disconnected
        _ws = null;
        _sendChannel?.Writer.TryComplete();
        _sendChannel = null;
        try { _cts?.Cancel(); } catch { }
        if (!string.IsNullOrEmpty(message))
            Callable.From(() => EmitSignal(SignalName.ErrorOccurred, message)).CallDeferred();
        Callable.From(() => EmitSignal(SignalName.Disconnected)).CallDeferred();
    }

    private void _EmitError(string message)
    {
        Callable.From(() => EmitSignal(SignalName.ErrorOccurred, message)).CallDeferred();
    }

    // On app quit, tell restim to go silent (volume 0) and neutralize position, then close.
    // Synchronous and best-effort — the e-stim equivalent of the serial DSTOP.
    public override void _Notification(int what)
    {
        if (what != NotificationWMCloseRequest && what != NotificationExitTree)
            return;

        var ws = _ws;
        if (ws == null || ws.State != WebSocketState.Open)
            return;

        // Stop the background send loop first so this synchronous send is the only
        // outstanding SendAsync on the socket (concurrent sends are illegal).
        try { _cts?.Cancel(); } catch { }

        try
        {
            var bytes = Encoding.ASCII.GetBytes("V00000 L05000");
            ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None)
                .Wait(200);
        }
        catch (Exception e)
        {
            GD.PrintErr($"RestimService: shutdown stop failed: {e.Message}");
        }
        try { ws.Abort(); } catch { }
        try { ws.Dispose(); } catch { }
        _ws = null;
    }
}
