using System;

// The stroke's rhythm and depth, for oscillating devices (OSCILLATE_DESIGN.md). A thrusting machine's
// stroke length is fixed, so what it can reproduce is how often the script turns round: its rhythm, in
// strokes per second. Rhythm alone would make a fast 0–20 flutter as intense as fast full strokes, when
// on a stroker it's a light buzz, so the depth of the strokes (how far each one travels, 0–100) is
// tracked alongside and scales the speed: fast and deep is full speed, fast and shallow is gentle.
//
// Fed one script segment at a time (keyframe to next keyframe, positions after effects). A half-stroke
// runs from one change of direction to the next, so a segment heading the same way as the last one
// just continues it, and scripts with points along each stroke measure the same as ones with points
// only at the ends. A segment that barely moves is a hold, which stops the rate outright: the machine
// should stop when the script does, not coast down over a stroke or two.
//
// Plain C# with no engine state, driven by FunscriptPlayer and checked through its StrokeRateOf and
// StrokeDepthOf hooks.
public sealed class StrokeRateTracker
{
    // Movement smaller than this (in 0–100 position units) is a hold, not a stroke: scripts often
    // jitter a point or two while "still".
    public const double MoveThreshold = 3.0;
    // A half-stroke shorter than this is noise (or a duplicated keyframe), not a 12-strokes-a-second
    // script.
    public const double MinHalfStrokeMs = 40.0;
    // A half-stroke longer than this means the clock jumped (a seek) or the script paused without a hold
    // point; the measurement falls back to the segment's own length.
    public const double MaxHalfStrokeMs = 4000.0;
    // How far each new half-stroke moves the estimates: about two strokes to settle on a new rhythm.
    public const double Smoothing = 0.5;

    private double _halfStartMs = -1.0;  // when the current half-stroke began
    private double _halfStartPos = 0.0;  // where it began
    private int _direction = 0;          // +1 up, -1 down, 0 = holding / not started
    private double _halfStrokeMs = 0.0;  // smoothed half-stroke length
    private double _depth = 0.0;         // smoothed half-stroke travel, 0–100
    private bool _holding = true;

    // Strokes per second right now; 0 while holding or before the first stroke.
    public double Rate => _holding || _halfStrokeMs <= 0.0 ? 0.0 : 1000.0 / (2.0 * _halfStrokeMs);

    // How far the strokes travel right now, 0–100; 0 while holding.
    public double Depth => _holding ? 0.0 : _depth;

    public void Reset()
    {
        Hold();
        _halfStrokeMs = 0.0;
        _depth = 0.0;
    }

    // The script (or an effect) is holding still. The next stroke starts a fresh measurement.
    public void Hold()
    {
        _holding = true;
        _direction = 0;
        _halfStartMs = -1.0;
    }

    public void FeedSegment(double startMs, double startPos, double endMs, double endPos)
    {
        double delta = endPos - startPos;
        double lengthMs = endMs - startMs;
        if (Math.Abs(delta) < MoveThreshold || lengthMs <= 0.0)
        {
            Hold();
            return;
        }

        int direction = Math.Sign(delta);
        if (!_holding && direction == _direction)
            return;  // the same half-stroke carrying on through another point

        // A turn: the half-stroke that just ended ran from its start to here. Coming out of a hold there
        // is no previous half-stroke, so this segment stands in until the next turn.
        bool fresh = _halfStartMs < 0.0;
        double measuredMs = fresh ? lengthMs : startMs - _halfStartMs;
        double measuredDepth = fresh ? Math.Abs(delta) : Math.Abs(startPos - _halfStartPos);
        if (measuredMs < MinHalfStrokeMs || measuredMs > MaxHalfStrokeMs)
        {
            measuredMs = Math.Clamp(lengthMs, MinHalfStrokeMs, MaxHalfStrokeMs);
            measuredDepth = Math.Abs(delta);
        }
        measuredDepth = Math.Clamp(measuredDepth, 0.0, 100.0);

        bool restart = _holding || _halfStrokeMs <= 0.0;
        _halfStrokeMs = restart ? measuredMs : _halfStrokeMs + (measuredMs - _halfStrokeMs) * Smoothing;
        _depth = restart ? measuredDepth : _depth + (measuredDepth - _depth) * Smoothing;

        _halfStartMs = startMs;
        _halfStartPos = startPos;
        _direction = direction;
        _holding = false;
    }
}
