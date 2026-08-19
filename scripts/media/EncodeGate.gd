class_name EncodeGate
extends RefCounted
## Serial queue for every ffmpeg encode, in two priority levels. Because it grants
## exactly one turn at a time, MediaPoolService's single _pid, single PROGRESS_FILE
## and single SEGMENT_BAKE_DIR stay safe by construction — no per-call scratch dirs,
## no PID ownership checks. That is the load-bearing decision of the background-baking
## design, and it holds only as long as every encode entry point runs through here.
##
## Not a Node: no file system, no OS.*, no clock, no get_tree(). The class is fully
## synchronous — turn_granted is emitted from inside acquire() and release() — which
## makes it testable without ffmpeg and keeps hand-off latency at zero.

enum Priority { FOREGROUND = 0, BACKGROUND = 1 }

## Emitted on every ownership change, carrying the ticket of the NEW holder. The
## payload is what lets several waiters tell their turn apart; callers loop on
## granted() and await this, never the bare signal.
signal turn_granted(ticket: int)

# Monotonic and never 0 — 0 is the "gate is free" marker for _holder, so reusing it
# as a ticket id would make granted() answer true for a long-finished job.
var _next_ticket: int = 1

var _holder: int = 0
var _holder_priority: int = Priority.FOREGROUND

# [{"ticket": int, "priority": int}] in arrival order. Invariant: a free gate
# (_holder == 0) implies an empty queue — a waiter with nobody running is a bug.
var _queue: Array[Dictionary] = []


## Draws a ticket. The gate may already be yours: check granted() before awaiting.
func acquire(priority: int) -> int:
	# Defensive coercion instead of an assert: a stray value must never slip past the
	# serialization, and FOREGROUND is the safe direction (it waits for nobody, so it
	# can at worst cost throughput, never correctness).
	var p: int = Priority.BACKGROUND if priority == Priority.BACKGROUND else Priority.FOREGROUND
	var ticket: int = _next_ticket
	_next_ticket += 1
	if _holder == 0:
		_holder = ticket
		_holder_priority = p
		# Fires on immediate grants too, so the rule stays a single sentence: every
		# ownership change emits exactly once with the new holder's ticket.
		turn_granted.emit(ticket)
		return ticket
	_queue.append({"ticket": ticket, "priority": p})
	return ticket


## True only for the ticket that currently owns the gate.
func granted(ticket: int) -> bool:
	return ticket != 0 and ticket == _holder


## Gives up the gate and hands it to the highest-priority waiter. Releasing a foreign,
## unknown, still-waiting or already-released ticket is a strict no-op — mandatory,
## not cosmetic: the encode entry points have up to seven return paths, and a double
## release would otherwise free the successor's ticket out from under it.
func release(ticket: int) -> void:
	if ticket == 0 or ticket != _holder:
		return
	_holder = 0
	var idx: int = _pick_next()
	if idx < 0:
		return
	var nxt: Dictionary = _queue[idx]
	_queue.remove_at(idx)
	_holder = int(nxt["ticket"])
	_holder_priority = int(nxt["priority"])
	turn_granted.emit(_holder)


## True when the holder should step aside for a waiting higher-priority job.
## MediaPoolService folds this into the caller's should_cancel, so the existing
## OS.kill(_pid) path preempts a background encode with no new cancel machinery.
func should_yield(ticket: int) -> bool:
	if ticket == 0 or ticket != _holder:
		return false  # non-holders (waiting or unknown) have nothing to step aside from
	for q: Dictionary in _queue:
		if int(q["priority"]) < _holder_priority:
			return true
	return false


## "A job is running right now" — not "somebody is waiting".
func is_busy() -> bool:
	return _holder != 0


# Index of the next holder: smallest priority value wins, ties go to the earliest
# arrival. That is exactly "FOREGROUND overtakes every waiting BACKGROUND, FIFO
# within a level". Returns -1 when nobody waits.
func _pick_next() -> int:
	var idx: int = -1
	var best: int = 0
	for i: int in _queue.size():
		var p: int = int(_queue[i]["priority"])
		if idx < 0 or p < best:
			idx = i
			best = p
	return idx
