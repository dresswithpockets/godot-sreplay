extends Control

@onready var _recording_label: Label = %RecordingLabel
@onready var _replaying_label: Label = %ReplayingLabel

@onready var _playback_control: Control = %PlaybackContainer
@onready var _scrubber: HSlider = %Scrubber

var _font_color: Color = Color.WHITE
var _font_outline_color: Color = Color.BLACK
var _time: float = 0

var _speed_control: float = 1.0

func _get_current_state() -> Dictionary:
    var player: Player = get_tree().get_first_node_in_group("player")
    return {
        "scene_path": get_tree().current_scene.scene_file_path,
        "player": player.to_state_dict(),
    }

func _set_current_state(state: Dictionary, always_change_scene: bool) -> void:
    var scene_path: String = state["scene_path"]
    var player_state: Dictionary = state["player"]
    
    var tree: SceneTree = get_tree()
    if always_change_scene or tree.get_root().scene_file_path != scene_path:
        assert(tree.change_scene_to_file(scene_path) == OK)
        await tree.process_frame
        await tree.process_frame
    
    var player: Player = tree.get_first_node_in_group("player")
    player.update_state_from_dict(player_state)

func _command_record() -> void:
    if SReplay.mode != SReplay.Mode.OFF:
        Console.print_error("Already recording a replay")
        return
    
    # recording on the idle frame is undefined behaviour
    await get_tree().physics_frame
    
    SReplay.record(_get_current_state)
    Console.print_info("Recording...")

func _command_stop() -> void:
    if SReplay.mode == SReplay.Mode.OFF:
        Console.print_error("Not currently recording or replaying anything")
        return
    
    SReplay.stop()
    Console.print_info("Stopped recording.")
    Engine.time_scale = 1.0

func _command_play() -> void:
    if SReplay.mode != SReplay.Mode.OFF:
        Console.print_error("Already recording or playing a replay")
        return
    
    assert(SReplay.recording.user_data is Dictionary)
    _set_current_state(SReplay.recording.user_data, true)

    # playing on the idle frame is undefined behaviour
    await get_tree().physics_frame
    SReplay.play(
        func(user_data: Variant) -> void:
            if user_data != null:
                _set_current_state(user_data, false)
    )
    Console.print_info("Playing...")

func _command_save(path: String) -> void:
    if SReplay.mode != SReplay.Mode.OFF:
        Console.print_error("Can't save while recording or replaying a replay")
        return
    
    var recording := SReplay.recording
    if !recording or recording.is_empty():
        Console.print_error("Can't save an empty replay")
        return
    
    if !path.ends_with(".json"):
        path += ".json"
    
    var as_dict := recording.to_dict()
    var as_json := JSON.stringify(as_dict, "  ")
    var file := FileAccess.open("user://replays/%s" % path, FileAccess.WRITE)
    if !file or !file.is_open():
        Console.print_error("Failed to save replay at '%s'" % path)
        return
    
    file.store_string(as_json)
    Console.print_info("Saved replay at '%s'" % path)

func _command_load(path: String) -> void:
    if SReplay.mode != SReplay.Mode.OFF:
        Console.print_error("Can't load a replay while recording or replaying")
        return
    
    if !path.ends_with(".json"):
        path += ".json"
    
    var file := FileAccess.open("user://replays/%s" % path, FileAccess.READ)
    if !file or !file.is_open():
        Console.print_error("Error opening replay at '%s'" % path)
        return
    
    var json := file.get_as_text(true)
    var dict = JSON.parse_string(json)
    var recording := SReplay.Recording.from_dict(dict)
    if recording.is_empty():
        Console.print_error("Can't load an empty replay")
        return

    SReplay.recording = recording
    Console.print_info("Loaded replay from '%s'" % path)

func _command_pause() -> void:
    await get_tree().physics_frame
    Engine.time_scale = 0.0

func _command_unpause() -> void:
    await get_tree().physics_frame
    Engine.time_scale = _speed_control

func _play_toggle_pressed() -> void:
    if Engine.time_scale == 0:
        Engine.time_scale = _speed_control
    else:
        Engine.time_scale = 0

func _restart() -> void:
    await get_tree().physics_frame

    Engine.time_scale = 0
    SReplay.restart()

    assert(SReplay.recording.user_data is Dictionary)
    _set_current_state(SReplay.recording.user_data, true)

func _step_forward() -> void:
    Engine.time_scale = 1
    await get_tree().physics_frame
    Engine.time_scale = 0

func _step_backward() -> void:
    if SReplay.current_tick == 0 or SReplay.shift_finished.is_connected(_step_backward_shift_finished):
        return

    Engine.time_scale = 1
    SReplay.shift_finished.connect(_step_backward_shift_finished, CONNECT_ONE_SHOT)
    SReplay.shift(SReplay.current_tick - 2, true)

func _step_backward_shift_finished() -> void:
    Engine.time_scale = 0

func _speed_button_pressed(speed: float) -> void:
    _speed_control = speed
    if Engine.time_scale != 0:
        Engine.time_scale = _speed_control

func _sreplay_mode_changed(_old: SReplay.Mode, new: SReplay.Mode) -> void:
    if new != SReplay.Mode.REPLAYING:
        _playback_control.visible = false
        _scrubber.max_value = SReplay.recording.max_tick

func _ready() -> void:
    Console.add_command("record", _command_record, [], 0, "Begin recording a replay, if we're not already recording one")
    Console.add_command("stop", _command_stop, [], 0, "Stop recording a replay")
    Console.add_command("play", _command_play, [], 0, "Playback the currently loaded replay")
    Console.add_command("save", _command_save, ["Replay Name"], 1, "Save the recorded replay to a file")
    Console.add_command("load", _command_load, ["Replay Name"], 1, "Load a replay from a file")
    Console.add_command("pause", _command_pause, [], 0, "Pause replay")
    Console.add_command("unpause", _command_unpause, [], 0, "Unpause replay")
    
    SReplay.mode_changed.connect(_sreplay_mode_changed)

func _unhandled_input(event: InputEvent) -> void:
    if SReplay.mode != SReplay.Mode.REPLAYING:
        return

    if !event.is_action_pressed("toggle_replay_ui"):
        return
    
    _playback_control.visible = !_playback_control.visible
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _process(delta: float) -> void:
    if SReplay.mode != SReplay.Mode.OFF:
        _time += delta
        _font_color.a = pingpong(_time, 1.0)
        _font_outline_color.a = pingpong(_time, 1.0)
    else:
        _font_color.a = 0
        _font_outline_color.a = 0
    
    _recording_label.visible = SReplay.mode == SReplay.Mode.RECORDING
    _replaying_label.visible = SReplay.mode == SReplay.Mode.REPLAYING
    
    _recording_label.add_theme_color_override("font_color", _font_color)
    _recording_label.add_theme_color_override("font_outline_color", _font_outline_color)
    _replaying_label.add_theme_color_override("font_color", _font_color)
    _replaying_label.add_theme_color_override("font_outline_color", _font_outline_color)


func _on_scrubber_drag_ended(value_changed: bool) -> void:
    if !value_changed or SReplay.mode != SReplay.Mode.REPLAYING:
        return
    
    Engine.time_scale = 1
    SReplay.shift_finished.connect(_step_backward_shift_finished, CONNECT_ONE_SHOT)
    SReplay.shift(roundi(_scrubber.value), true)
