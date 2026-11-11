extends GdUnitTestSuite

# The HARDWARE VIDEO DECODING switch reaches the video add-on through a project setting, which the add-on reads as
# each video opens.

var _was_on: bool


func before_test() -> void:
	_was_on = SettingsService.get_hardware_video_decoding()


func after_test() -> void:
	SettingsService.set_hardware_video_decoding(_was_on)


func test_the_switch_reaches_the_video_add_on() -> void:
	SettingsService.set_hardware_video_decoding(false)
	(
		assert_bool(ProjectSettings.get_setting(SettingsService.HARDWARE_VIDEO_DECODING_SETTING))
		. is_false()
	)
	SettingsService.set_hardware_video_decoding(true)
	(
		assert_bool(ProjectSettings.get_setting(SettingsService.HARDWARE_VIDEO_DECODING_SETTING))
		. is_true()
	)
