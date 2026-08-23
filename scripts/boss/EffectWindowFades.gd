class_name EffectWindowFades
extends RefCounted
## Ease-in / ease-out bookkeeping for a boss timeline's EFFECT WINDOWS. A window that snaps on reads as
## a glitch rather than a deliberate moment, so an author can give it a fade; this tracks how far through
## each open window is, as a 0..1 factor its sensory intensities are scaled by.
##
## Pure state and arithmetic — it applies nothing itself. Both the GameLoop (the real round) and the
## encounter editor's preview stage drive it and read `factor()`, which is the point: the fade an author
## tunes is the fade they see previewed AND the fade that plays, because there is only one
## implementation of it. Writing this twice is exactly how a preview drifts from the runtime.
##
## The caller owns removal. `end()` says whether a window is easing out — if so the caller keeps its
## effects applied until `tick()` reports the window finished.

# source_id → {factor: float, target: float, rate: float}
#   factor  where the ramp is now (0..1)
#   target  where it is heading — 1 easing in, 0 easing out
#   rate    factor per second; 0 means "arrive immediately"
var _fades: Dictionary = {}


## Starts a window's ease-in. A window with no authored fade still gets a record, at full strength, so
## an ease-OUT later has somewhere to ramp from — otherwise a hard-in / soft-out window would snap at
## both ends.
func begin(source_id: String, event: Dictionary) -> void:
	var fade_in_ms: int = int(event.get("fade_in_ms", 0))
	var immediate: bool = fade_in_ms <= 0
	_fades[source_id] = {
		"factor": 1.0 if immediate else 0.0,
		"target": 1.0,
		"rate": 0.0 if immediate else 1000.0 / float(fade_in_ms),
	}


## Turns a window's ramp toward zero. Returns true when it will ease out — the caller then leaves the
## window applied until tick() lists it as finished. False means "nothing to ease": drop it now.
func end(source_id: String, event: Dictionary) -> bool:
	var fade_out_ms: int = int(event.get("fade_out_ms", 0))
	if fade_out_ms <= 0 or not _fades.has(source_id):
		_fades.erase(source_id)
		return false
	var fade: Dictionary = _fades[source_id]
	fade["target"] = 0.0
	fade["rate"] = 1000.0 / float(fade_out_ms)
	return true


## Advances every ramp by `delta` seconds. Returns `{changed: [source_id…], finished: [source_id…]}` —
## `changed` is what the caller should re-apply, `finished` what it should now drop for good.
func tick(delta: float) -> Dictionary:
	var changed: Array = []
	var finished: Array = []
	for id: Variant in _fades:
		var fade: Dictionary = _fades[id]
		var target: float = float(fade["target"])
		var factor: float = float(fade["factor"])
		if is_equal_approx(factor, target):
			if target <= 0.0:
				finished.append(str(id))
			continue
		var rate: float = float(fade["rate"])
		factor = target if rate <= 0.0 else move_toward(factor, target, rate * delta)
		fade["factor"] = factor
		changed.append(str(id))
		if target <= 0.0 and factor <= 0.0:
			finished.append(str(id))
	for id: String in finished:
		_fades.erase(id)
	return {"changed": changed, "finished": finished}


## How far through its fade a window is, 0..1. An unknown window reads as 1.0, so a caller that never
## registered one still gets full strength rather than silence.
func factor(source_id: String) -> float:
	if not _fades.has(source_id):
		return 1.0
	return float((_fades[source_id] as Dictionary)["factor"])


## True while anything is mid-ramp, so a caller can skip the per-frame work entirely.
func is_active() -> bool:
	return not _fades.is_empty()


## Abandons every ramp — the round ended, or the preview jumped somewhere else.
func clear() -> void:
	_fades.clear()
