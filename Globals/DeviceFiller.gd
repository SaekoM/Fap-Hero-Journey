extends Node

## The storyboard filler's one entry point: a plain alternating stroke sent to every connected device.
##
## There are two ways a stroke reaches hardware in this app, and the filler needs both. Serial and
## Buttplug devices take one "go to X over N ms" command per half-stroke, which FunscriptPlayer issues
## from its own tick. A Handy on direct WiFi takes a streamed point script instead, which is why the
## filler never reached one — FunscriptPlayer's filler has no path to it, so a storyboard (and the
## builder's test button) left a WiFi Handy sitting still.
##
## Neither backend minds being asked when it isn't there: each call no-ops on a device that isn't
## connected, so callers say "fill" once and every device that can hear it does.

const MIN_HALF_CYCLE_MS: int = 50


## Starts the stroke on every connected device. `lo`/`hi` are 0-100 positions (either order),
## `half_cycle_ms` is one stroke in one direction.
func start(lo: int, hi: int, half_cycle_ms: int) -> void:
	var half: int = maxi(MIN_HALF_CYCLE_MS, half_cycle_ms)
	var bottom: int = clampi(mini(lo, hi), 0, 100)
	var top: int = clampi(maxi(lo, hi), 0, 100)
	FunscriptPlayer.StartFiller(bottom, top, half)
	# Fire-and-forget: the Handy path is HTTP, and a caller opening a storyboard shouldn't wait on a
	# round trip to show it. A failure there is already reported by HandyService.
	HandyService.start_filler(bottom, top, half)


## Re-aims a running stroke without restarting it, for a live edit while testing.
func set_params(lo: int, hi: int, half_cycle_ms: int) -> void:
	var half: int = maxi(MIN_HALF_CYCLE_MS, half_cycle_ms)
	var bottom: int = clampi(mini(lo, hi), 0, 100)
	var top: int = clampi(maxi(lo, hi), 0, 100)
	FunscriptPlayer.SetFillerParams(bottom, top, half)
	# The Handy is looping a script rather than taking commands, so a new aim IS a new script.
	if HandyService.is_filler_active():
		HandyService.start_filler(bottom, top, half)


## Stops every device. Both halves are idempotent and neither is conditional on this having started
## the stroke — a stop is the one call that must never be skipped on a guess about what is running.
func stop() -> void:
	FunscriptPlayer.StopFiller()
	HandyService.stop_filler()
