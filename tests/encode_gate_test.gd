extends GdUnitTestSuite

# EncodeGate — the serial queue that makes concurrent ffmpeg encodes structurally
# impossible instead of merely unlikely. Because it guarantees a single encode at a
# time, MediaPoolService keeps one _pid, one PROGRESS_FILE and one SEGMENT_BAKE_DIR
# without per-call scoping; every assertion here is therefore load-bearing for the
# safety of that decision, not for the gate alone.
#
# The gate is a RefCounted with no I/O, no OS.*, no clock and no frame loop, so the
# whole suite runs synchronously — turn_granted is emitted from inside acquire and
# release. Only the two signal cases need the async gdUnit tooling, and then only
# because assert_signal is a coroutine.

const FG: int = EncodeGate.Priority.FOREGROUND
const BG: int = EncodeGate.Priority.BACKGROUND

# ── Handing the gate over ────────────────────────────────────────────────────


# The first caller walks straight through; everyone after it queues. is_busy means
# "a job is running", not "someone is waiting".
func test_first_ticket_is_granted_and_second_waits() -> void:
	var gate := EncodeGate.new()
	assert_bool(gate.is_busy()).is_false()
	var t1: int = gate.acquire(FG)
	var t2: int = gate.acquire(FG)
	assert_bool(gate.granted(t1)).is_true()
	assert_bool(gate.granted(t2)).is_false()
	assert_bool(gate.is_busy()).is_true()


# is_busy() answers "is a job running", not "is anyone waiting". A single
# acquire with nobody queued must already report busy, and releasing that
# lone ticket must drop it back to idle. The mutation `return not
# _queue.is_empty()` gets both halves backwards but slips past the test
# above because that one always leaves a second ticket in the queue.
func test_is_busy_reflects_the_holder_not_the_queue() -> void:
	var gate := EncodeGate.new()
	var t1: int = gate.acquire(FG)
	assert_bool(gate.is_busy()).is_true()  # nobody waiting, yet a job is running
	gate.release(t1)
	assert_bool(gate.is_busy()).is_false()


# Within one priority level the order is arrival order — a background job that
# queued first is not pushed back by a later one of the same level.
func test_same_priority_is_served_in_draw_order() -> void:
	var gate := EncodeGate.new()
	var holder: int = gate.acquire(FG)  # keeps the gate busy so both BG tickets queue
	var b1: int = gate.acquire(BG)
	var b2: int = gate.acquire(BG)
	gate.release(holder)
	assert_bool(gate.granted(b1)).is_true()
	assert_bool(gate.granted(b2)).is_false()
	gate.release(b1)
	assert_bool(gate.granted(b2)).is_true()


# The whole point of the two levels: a visible job (builder save, randomizer
# prepare) jumps every waiting prebake, no matter how long that one has queued.
# The leftovers keep their own arrival order afterwards.
func test_foreground_overtakes_waiting_background_tickets() -> void:
	var gate := EncodeGate.new()
	var holder: int = gate.acquire(FG)
	var b1: int = gate.acquire(BG)
	var b2: int = gate.acquire(BG)
	var f1: int = gate.acquire(FG)  # drawn last, served first
	gate.release(holder)
	assert_bool(gate.granted(f1)).is_true()
	gate.release(f1)
	assert_bool(gate.granted(b1)).is_true()
	gate.release(b1)
	assert_bool(gate.granted(b2)).is_true()


# ── Preemption ───────────────────────────────────────────────────────────────


# should_yield is what MediaPoolService folds into the caller's should_cancel, so
# the existing OS.kill(_pid) path preempts a background encode. It answers "must
# I step aside?" and therefore only ever concerns the current holder.
func test_should_yield_is_true_only_for_a_background_holder() -> void:
	var gate := EncodeGate.new()
	var bg: int = gate.acquire(BG)
	assert_bool(gate.should_yield(bg)).is_false()  # nobody waiting
	var bg2: int = gate.acquire(BG)
	assert_bool(gate.should_yield(bg)).is_false()  # same level never preempts
	var fg: int = gate.acquire(FG)
	assert_bool(gate.should_yield(bg)).is_true()
	# Non-holders never yield: neither the waiting tickets nor anything unknown.
	assert_bool(gate.should_yield(fg)).is_false()
	assert_bool(gate.should_yield(bg2)).is_false()
	assert_bool(gate.should_yield(0)).is_false()
	assert_bool(gate.should_yield(fg + 999)).is_false()
	# Once the foreground job holds the gate it never yields, background still queued.
	gate.release(bg)
	assert_bool(gate.granted(fg)).is_true()
	assert_bool(gate.should_yield(fg)).is_false()


# ── Priority handover via release ────────────────────────────────────────────


# release() must set _holder_priority to the newly appointed holder's OWN
# priority, not leave it at the outgoing holder's. A background ticket that
# becomes holder this way — the ordinary path once a foreground job finishes
# and a prebake is next in line — still has to yield the instant a later
# foreground ticket starts waiting. Both existing should_yield tests only
# ever check a holder that got the gate for free via acquire(), so a gate
# that forgot to update _holder_priority in release() would never make a
# release-appointed background holder step aside for the builder's save.
func test_should_yield_reflects_priority_of_holder_appointed_by_release() -> void:
	var gate := EncodeGate.new()
	var fg1: int = gate.acquire(FG)
	var bg: int = gate.acquire(BG)  # queues behind fg1
	gate.release(fg1)  # bg becomes holder THROUGH release, not acquire on a free gate
	assert_bool(gate.granted(bg)).is_true()
	var _fg2: int = gate.acquire(FG)  # queues behind the new bg holder
	assert_bool(gate.should_yield(bg)).is_true()


# The mirror case: a foreground ticket appointed holder by release must never
# yield, even with a background ticket still waiting behind it.
func test_should_yield_false_for_foreground_holder_appointed_by_release() -> void:
	var gate := EncodeGate.new()
	var holder: int = gate.acquire(BG)
	var fg2: int = gate.acquire(FG)  # queues behind holder
	var _bg2: int = gate.acquire(BG)  # queues behind fg2, same level as holder
	gate.release(holder)  # fg2 becomes holder through release (FG outranks bg2)
	assert_bool(gate.granted(fg2)).is_true()
	assert_bool(gate.should_yield(fg2)).is_false()


# ── Release discipline ───────────────────────────────────────────────────────


# The encode entry points have up to seven return paths; a stray or repeated
# release would hand the gate to the successor while the first job still runs.
# Foreign, unknown, waiting and already-released tickets are all strict no-ops.
func test_foreign_double_and_waiting_release_are_no_ops() -> void:
	var gate := EncodeGate.new()
	var holder: int = gate.acquire(FG)
	var waiting: int = gate.acquire(BG)
	gate.release(waiting)  # a queued ticket stays queued
	gate.release(0)
	gate.release(holder + 999)
	assert_bool(gate.granted(holder)).is_true()
	assert_bool(gate.granted(waiting)).is_false()
	gate.release(holder)
	assert_bool(gate.granted(waiting)).is_true()  # still in the queue, now the holder
	gate.release(holder)  # the double release must not pass the gate on again
	assert_bool(gate.granted(waiting)).is_true()
	gate.release(waiting)
	assert_bool(gate.is_busy()).is_false()


# ── Signal contract ──────────────────────────────────────────────────────────


# Every ownership change emits exactly once, carrying the NEW holder's ticket —
# including the immediate grant inside acquire. Callers loop on granted() and wait
# on this signal, so a payload naming the wrong ticket would wake the wrong waiter.
func test_turn_granted_carries_the_new_holder_ticket(timeout := 5000) -> void:
	var gate := monitor_signals(EncodeGate.new()) as EncodeGate
	var t1: int = gate.acquire(FG)
	var t2: int = gate.acquire(BG)
	var t3: int = gate.acquire(BG)
	await assert_signal(gate).is_emitted("turn_granted", [t1])
	gate.release(t1)
	await assert_signal(gate).is_emitted("turn_granted", [t2])
	assert_bool(gate.granted(t3)).is_false()  # the second waiter is not woken by t2's turn


# Contract rule §2.2: exactly one emission per ownership change. acquire() on
# a busy gate only enqueues the ticket, so it must stay silent for that
# ticket — firing early would wake a waiter that does not yet hold the gate.
func test_turn_granted_is_not_emitted_for_a_ticket_that_only_queues(timeout := 5000) -> void:
	var gate := monitor_signals(EncodeGate.new()) as EncodeGate
	var t1: int = gate.acquire(FG)
	var t2: int = gate.acquire(FG)  # gate is busy: queues, must not emit for t2
	await assert_signal(gate).is_emitted("turn_granted", [t1])
	await assert_signal(gate).wait_until(50).is_not_emitted("turn_granted", [t2])


# ── Ticket identity ──────────────────────────────────────────────────────────


# 0 is the "no holder" marker, so it must never be a real ticket, and ids are never
# recycled — granted() would otherwise answer true for a long-finished job.
func test_ticket_ids_are_monotonic_and_never_zero() -> void:
	var gate := EncodeGate.new()
	var tickets: Array[int] = []
	for i: int in 4:
		tickets.append(gate.acquire(FG if i % 2 == 0 else BG))
	var last: int = 0
	for t: int in tickets:
		assert_int(t).is_not_equal(0)
		assert_int(t).is_greater(last)
		last = t
	gate.release(tickets[0])
	assert_int(gate.acquire(FG)).is_greater(last)


# A value that is neither enum member counts as FOREGROUND: a stray priority may
# cost throughput, but it must never let a job slip past the serialization or
# silently outrank a real foreground job.
func test_unknown_priority_is_coerced_to_foreground() -> void:
	var gate := EncodeGate.new()
	var holder: int = gate.acquire(BG)
	var odd: int = gate.acquire(7)
	var bg: int = gate.acquire(BG)
	assert_bool(gate.should_yield(holder)).is_true()  # coerced ticket outranks the holder
	gate.release(holder)
	assert_bool(gate.granted(odd)).is_true()
	assert_bool(gate.granted(bg)).is_false()
	assert_bool(gate.should_yield(odd)).is_false()  # and as holder it is a foreground job
