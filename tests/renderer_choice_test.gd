extends GdUnitTestSuite

# The RENDERER choice is written to the settings override file that project.godot names, which Godot reads at launch.
# These tests write the player's real override file, so each one puts back exactly what was there before.

var _file_existed: bool
var _saved_text: String


func before_test() -> void:
	_file_existed = FileAccess.file_exists(SettingsService.RENDERER_OVERRIDE_PATH)
	if _file_existed:
		_saved_text = FileAccess.get_file_as_string(SettingsService.RENDERER_OVERRIDE_PATH)


func after_test() -> void:
	if _file_existed:
		var file: FileAccess = FileAccess.open(
			SettingsService.RENDERER_OVERRIDE_PATH, FileAccess.WRITE
		)
		file.store_string(_saved_text)
		file.close()
	else:
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(SettingsService.RENDERER_OVERRIDE_PATH)
		)


func test_project_reads_the_override_file_the_choice_is_written_to() -> void:
	(
		assert_str(str(ProjectSettings.get_setting("application/config/project_settings_override")))
		. is_equal(SettingsService.RENDERER_OVERRIDE_PATH)
	)


func test_a_choice_is_written_where_godot_looks_for_it() -> void:
	SettingsService.set_renderer(SettingsService.RENDERER_VULKAN)
	var override: ConfigFile = ConfigFile.new()
	assert_int(override.load(SettingsService.RENDERER_OVERRIDE_PATH)).is_equal(OK)
	(
		assert_str(str(override.get_value("rendering", "rendering_device/driver.windows", "")))
		. is_equal(SettingsService.RENDERER_VULKAN)
	)
	assert_str(SettingsService.get_renderer()).is_equal(SettingsService.RENDERER_VULKAN)
	SettingsService.set_renderer(SettingsService.RENDERER_D3D12)
	assert_str(SettingsService.get_renderer()).is_equal(SettingsService.RENDERER_D3D12)


func test_an_unknown_renderer_is_refused() -> void:
	SettingsService.set_renderer(SettingsService.RENDERER_D3D12)
	SettingsService.set_renderer("opengl3")
	assert_str(SettingsService.get_renderer()).is_equal(SettingsService.RENDERER_D3D12)


func test_every_renderer_has_a_name() -> void:
	for renderer: String in SettingsService.RENDERERS:
		assert_bool(SettingsService.RENDERER_NAMES.has(renderer)).is_true()
