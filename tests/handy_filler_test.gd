extends GdUnitTestSuite

# The filler's trip to a WiFi Handy: a stroke can change far faster than the network can carry it, so uploads
# run one at a time and only the newest counts. Spinning Double or Nothing's wheel used to flood the device,
# and a superseded upload could send a stop that landed after the newest one.

const UPLOAD_SETTLE_MS: int = 1200
const FULL_LOOP_HALF_MS: int = 400


# HandyService with the network replaced: records every call and answers a frame later.
class FakeHandy:
	extends "res://Globals/HandyService.gd"

	var endpoints: Array[String] = []
	var plays: Array[Dictionary] = []
	var answer_with_failure: bool = false

	func _ready() -> void:
		_connected = true

	func _api_put(endpoint: String, payload: Dictionary) -> Dictionary:
		endpoints.append(endpoint)
		if endpoint == "/hsp/play":
			plays.append(payload)
		await get_tree().process_frame
		return {} if answer_with_failure else {"result": "ok"}


func _handy() -> FakeHandy:
	var handy: FakeHandy = auto_free(FakeHandy.new())
	add_child(handy)
	return handy


func _first_half_stroke_ms(play: Dictionary) -> int:
	var points: Array = play["add"]["points"]
	return int(points[1]["t"]) - int(points[0]["t"])


func test_a_burst_of_changes_uploads_the_newest_and_never_stops_the_device() -> void:
	var handy: FakeHandy = _handy()
	for half_ms: int in range(1000, 500, -10):
		handy.start_filler(0, 100, half_ms)
		await get_tree().process_frame
	handy.start_filler(0, 100, FULL_LOOP_HALF_MS)
	await await_millis(UPLOAD_SETTLE_MS)

	assert_bool(handy.endpoints.has("/hsp/stop")).is_false()
	assert_int(handy.plays.size()).is_less_equal(4)
	assert_int(_first_half_stroke_ms(handy.plays[-1])).is_equal(FULL_LOOP_HALF_MS)


func test_a_failed_upload_does_not_block_the_next_change() -> void:
	var handy: FakeHandy = _handy()
	handy.answer_with_failure = true
	handy.start_filler(0, 100, 1000)
	await await_millis(UPLOAD_SETTLE_MS)
	assert_bool(handy.is_filler_active()).is_true()

	handy.answer_with_failure = false
	handy.start_filler(0, 100, FULL_LOOP_HALF_MS)
	await await_millis(UPLOAD_SETTLE_MS)
	assert_int(_first_half_stroke_ms(handy.plays[-1])).is_equal(FULL_LOOP_HALF_MS)


# The stop goes out before the play in flight lands, so the device needs a second one after it.
func test_a_stop_during_an_upload_still_leaves_the_device_stopped() -> void:
	var handy: FakeHandy = _handy()
	handy.start_filler(0, 100, 1000)
	await get_tree().process_frame  # the setup has answered; the play is on its way
	await get_tree().process_frame
	handy.stop_filler()
	await await_millis(UPLOAD_SETTLE_MS)

	assert_bool(handy.is_filler_active()).is_false()
	assert_str(handy.endpoints[-1]).is_equal("/hsp/stop")


func test_easing_home_glides_to_the_middle_from_where_the_stroke_is() -> void:
	var handy: FakeHandy = _handy()
	handy.start_filler(0, 100, 1000)
	await await_millis(UPLOAD_SETTLE_MS)
	handy.ease_filler_home()
	await await_millis(UPLOAD_SETTLE_MS)

	var ease: Dictionary = handy.plays[-1]
	var points: Array = ease["add"]["points"]
	assert_bool(ease["loop"]).is_false()
	assert_int(points.size()).is_equal(2)
	assert_int(int(points[1]["x"])).is_equal(50)
	assert_bool(handy.is_filler_active()).is_false()
	assert_bool(handy.endpoints.has("/hsp/stop")).is_false()


# With nothing landed yet there's no stroke to glide from, so it simply stops.
func test_easing_home_before_anything_has_played_just_stops() -> void:
	var handy: FakeHandy = _handy()
	handy.start_filler(0, 100, 1000)
	handy.ease_filler_home()
	await await_millis(UPLOAD_SETTLE_MS)
	assert_str(handy.endpoints[-1]).is_equal("/hsp/stop")
	assert_bool(handy.is_filler_active()).is_false()


func test_a_walk_is_one_upload() -> void:
	var handy: FakeHandy = _handy()
	handy.start_filler(0, 100, 1000)
	await await_millis(UPLOAD_SETTLE_MS)
	var plays_before: int = handy.plays.size()
	handy.start_filler_walk(100, 260, 3400)
	await await_millis(UPLOAD_SETTLE_MS)
	assert_int(handy.plays.size()).is_equal(plays_before + 1)
	assert_bool(handy.plays[-1]["loop"]).is_false()


func test_nothing_is_uploaded_while_a_round_owns_the_device() -> void:
	var handy: FakeHandy = _handy()
	handy._playing = true
	handy.start_filler(0, 100, 1000)
	handy.start_filler_walk(100, 260, 3400)
	await await_millis(UPLOAD_SETTLE_MS)
	assert_array(handy.endpoints).is_empty()
