class_name AutoblowScript
extends RefCounted

# Pure helpers for AutoblowService: the script a device is sent, the multipart body that carries it, which API a
# device answers on, how fast filler runs, and how long a rate limit asks us to wait. Kept off the autoload so it's
# unit-testable without one, like HandyPoints for the Handy.
#
# Autoblow's API (developers.autoblow.com, HTTP API v1) takes a WHOLE funscript per round rather than a stream. It
# has no stroke-range setting for scripts, so the player's range is baked into the positions here.

const DEVICE_ULTRA: String = "autoblow-ultra"
const DEVICE_VACUGLIDE: String = "vacuglide"
# The path each device's API lives under, keyed by the deviceType its /connected answers with.
const API_PREFIXES: Dictionary = {DEVICE_ULTRA: "/autoblow", DEVICE_VACUGLIDE: "/vacuglide"}
const DEVICE_NAMES: Dictionary = {DEVICE_ULTRA: "Autoblow Ultra", DEVICE_VACUGLIDE: "Vacuglide"}

# The API's limits on a sync script.
const MAX_ACTIONS: int = 100000
const MAX_LAST_ACTION_MS: int = 16777214

# Filler speed: the API takes 0-100 % with no stated stroke rate, so this is a guess to tune on a real device.
# A half-stroke this long or shorter runs at 100 %; this long or longer at the slowest speed that still moves.
const FASTEST_HALF_STROKE_MS: int = 150
const SLOWEST_HALF_STROKE_MS: int = 1500
const SLOWEST_SPEED: int = 5
# The Ultra's oscillator needs its low and high points at least this far apart.
const MIN_OSCILLATE_SPAN: int = 10

const RATE_LIMIT_FALLBACK_WAIT_MS: int = 2000  # a 429 without a usable reset header
const RATE_LIMIT_LONGEST_WAIT_MS: int = 30000


# The script as sent: HSP-style points ({t, x}) squeezed into the player's stroke range, cut to the API's limits,
# as funscript JSON bytes.
static func funscript_bytes(points: Array, range_min: int, range_max: int) -> PackedByteArray:
	var actions: Array = []
	for point: Dictionary in points:
		var at: int = int(point["t"])
		if at > MAX_LAST_ACTION_MS or actions.size() >= MAX_ACTIONS:
			break
		actions.append({"at": at, "pos": in_range(int(point["x"]), range_min, range_max)})
	return (
		JSON
		. stringify({"version": "1.0", "inverted": false, "range": 100, "actions": actions})
		. to_utf8_buffer()
	)


# A 0-100 position placed inside the player's stroke range (range_min..range_max), so 0 lands on the bottom of the
# range and 100 on its top.
static func in_range(pos: int, range_min: int, range_max: int) -> int:
	var low: int = clampi(mini(range_min, range_max), 0, 100)
	var high: int = clampi(maxi(range_min, range_max), 0, 100)
	return roundi(lerpf(low, high, clampi(pos, 0, 100) / 100.0))


# A multipart/form-data body carrying one file field named "file". Returns {content_type, body}.
static func multipart_file(
	file_name: String, file_bytes: PackedByteArray, boundary: String
) -> Dictionary:
	var body: PackedByteArray = PackedByteArray()
	var head: String = (
		(
			'--%s\r\nContent-Disposition: form-data; name="file"; filename="%s"\r\n'
			% [boundary, file_name]
		)
		+ "Content-Type: application/json\r\n\r\n"
	)
	body.append_array(head.to_utf8_buffer())
	body.append_array(file_bytes)
	body.append_array(("\r\n--%s--\r\n" % boundary).to_utf8_buffer())
	return {"content_type": "multipart/form-data; boundary=" + boundary, "body": body}


# The API path prefix for a device type, or "" for one this build doesn't drive (the VacuPump, by decision).
static func api_prefix(device_type: String) -> String:
	return str(API_PREFIXES.get(device_type, ""))


# A filler stroke's half-cycle as the API's 0-100 % speed: shorter half-strokes are faster.
static func filler_speed(half_cycle_ms: int) -> int:
	var share: float = inverse_lerp(
		float(SLOWEST_HALF_STROKE_MS), float(FASTEST_HALF_STROKE_MS), float(half_cycle_ms)
	)
	return clampi(roundi(lerpf(SLOWEST_SPEED, 100.0, clampf(share, 0.0, 1.0))), SLOWEST_SPEED, 100)


# The Ultra oscillator's low and high points for a filler stroke, kept the API's minimum distance apart.
static func oscillate_span(bottom: int, top: int) -> Vector2i:
	var low: int = clampi(mini(bottom, top), 0, 100)
	var high: int = clampi(maxi(bottom, top), 0, 100)
	if high - low < MIN_OSCILLATE_SPAN:
		high = mini(100, low + MIN_OSCILLATE_SPAN)
		low = high - MIN_OSCILLATE_SPAN
	return Vector2i(low, high)


# How long a 429 asks us to wait, from the response headers. x-ratelimit-reset may be seconds to wait or a Unix time
# in seconds (the docs don't say which); both are read, and anything unusable waits the fallback.
static func rate_limit_wait_ms(headers: PackedStringArray, now_unix_s: float) -> int:
	var reset: float = header_value(headers, "x-ratelimit-reset").to_float()
	if reset <= 0.0:
		return RATE_LIMIT_FALLBACK_WAIT_MS
	var wait_s: float = reset - now_unix_s if reset > 1000000000.0 else reset
	return clampi(roundi(wait_s * 1000.0), 0, RATE_LIMIT_LONGEST_WAIT_MS)


# One response header's value by name (case-insensitive), or "" when it's absent.
static func header_value(headers: PackedStringArray, name: String) -> String:
	for header: String in headers:
		var split: int = header.find(":")
		if split > 0 and header.substr(0, split).strip_edges().to_lower() == name.to_lower():
			return header.substr(split + 1).strip_edges()
	return ""
