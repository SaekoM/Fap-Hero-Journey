class_name MultiSelectDropdown
extends MenuButton

## A dropdown that stays open for checking MULTIPLE options — a true multi-select picker (Godot's
## OptionButton is single-select only). Populate with set_options([{id, label}]); read/write the checked
## set via get_selected() / set_selected(); listen to selection_changed(ids).
##
## Built on MenuButton + a checkable PopupMenu with hide_on_checkable_item_selection = false, so a click
## toggles one option and leaves the list open for the next. The button label summarises the current
## selection ("None", the labels when few, or "N selected").

signal selection_changed(selected_ids: Array)

# Shown on the button when nothing is checked.
var empty_text: String = "None"
# Above this many selected, the button shows "N selected" instead of the full label list.
var summary_cap: int = 2

var _options: Array = []  # [{id: String, label: String}] in display order
var _selected: Dictionary = {}  # id -> true (membership set)


func _ready() -> void:
	flat = false  # ensure the styled box renders regardless of the ambient theme
	var pm: PopupMenu = get_popup()
	pm.hide_on_checkable_item_selection = false  # keep the list open for multi-pick
	pm.id_pressed.connect(_on_item_pressed)
	_refresh_text()


# Replace the option set. Each entry is {id, label}. Preserves any current selection whose id survives.
func set_options(options: Array) -> void:
	_options = options
	_rebuild()


# Set the checked ids (ids not in the options are ignored on display but kept in the model).
func set_selected(ids: Array) -> void:
	_selected = {}
	for id: Variant in ids:
		_selected[str(id)] = true
	_sync_checks()
	_refresh_text()


# The checked ids, in the options' display order.
func get_selected() -> Array:
	var out: Array = []
	for o: Dictionary in _options:
		if _selected.has(str(o["id"])):
			out.append(str(o["id"]))
	return out


func _rebuild() -> void:
	var pm: PopupMenu = get_popup()
	pm.clear()
	for i: int in _options.size():
		pm.add_check_item(str(_options[i].get("label", "")), i)  # item id = index into _options
		var tip: String = str(_options[i].get("tooltip", ""))
		if tip != "":
			pm.set_item_tooltip(pm.get_item_index(i), tip)
	_sync_checks()
	_refresh_text()


# Toggle the clicked option. `id` is the index into _options we assigned in _rebuild.
func _on_item_pressed(id: int) -> void:
	if id < 0 or id >= _options.size():
		return
	var opt_id: String = str(_options[id]["id"])
	if _selected.has(opt_id):
		_selected.erase(opt_id)
	else:
		_selected[opt_id] = true
	_sync_checks()
	_refresh_text()
	selection_changed.emit(get_selected())


# Paint every item's checkmark from the model (authoritative — robust to any engine auto-toggle).
func _sync_checks() -> void:
	var pm: PopupMenu = get_popup()
	for i: int in _options.size():
		var idx: int = pm.get_item_index(i)
		if idx >= 0:
			pm.set_item_checked(idx, _selected.has(str(_options[i]["id"])))


func _refresh_text() -> void:
	var labels: Array = []
	for o: Dictionary in _options:
		if _selected.has(str(o["id"])):
			labels.append(str(o["label"]))
	if labels.is_empty():
		text = empty_text
	elif labels.size() <= summary_cap:
		text = ", ".join(PackedStringArray(labels))
	else:
		text = "%d selected" % labels.size()
