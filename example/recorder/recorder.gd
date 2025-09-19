extends Control

@onready var _recording_label: Label = %RecordingLabel
@onready var _replaying_label: Label = %ReplayingLabel

@onready var _playback_control: Control = %PlaybackContainer
@onready var _scrubber: HSlider = %Scrubber
var _scrubber_dragging: bool = false

var _font_color: Color = Color.WHITE
var _font_outline_color: Color = Color.BLACK
var _time: float = 0

var _speed_control: SReplay.Rate = SReplay.Rate.FULL

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
    if always_change_scene or tree.current_scene.scene_file_path != scene_path:
        var scene: PackedScene = load(scene_path)
        assert(tree.change_scene_to_packed(scene) == OK)
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
    get_tree().paused = false
    Console.print_info("Stopped recording/replaying.")

func _command_play() -> void:
    if SReplay.mode != SReplay.Mode.OFF:
        Console.print_error("Already recording or playing a replay")
        return
    
    #assert(SReplay.recording.user_data is Dictionary)
    #@warning_ignore("unsafe_call_argument")
    #_set_current_state(SReplay.recording.user_data, true)

    # playing on the idle frame is undefined behaviour
    await get_tree().physics_frame
    SReplay.play(
        func(user_data: Variant) -> void:
            assert(user_data is Dictionary)
            @warning_ignore("unsafe_call_argument")
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
    var result: Variant = JSON.parse_string(json)
    
    assert(result is Dictionary)
    @warning_ignore("unsafe_call_argument")
    var recording := SReplay.Recording.from_dict(result)
    if recording.is_empty():
        Console.print_error("Can't load an empty replay")
        return

    SReplay.recording = recording
    Console.print_info("Loaded replay from '%s'" % path)

func _command_pause() -> void:
    SReplay.playback_rate = SReplay.Rate.PAUSED
    get_tree().paused = true

func _command_unpause() -> void:
    SReplay.playback_rate = _speed_control
    Engine.time_scale = _speed_control / float(SReplay.Rate.FULL)
    get_tree().paused = false

func _play_toggle_pressed() -> void:
    if SReplay.playback_rate == SReplay.Rate.PAUSED:
        SReplay.playback_rate = _speed_control
        Engine.time_scale = _speed_control / float(SReplay.Rate.FULL)
        get_tree().paused = false
    else:
        SReplay.playback_rate = SReplay.Rate.PAUSED
        get_tree().paused = true

func _restart() -> void:
    SReplay.playback_rate = SReplay.Rate.PAUSED
    get_tree().paused = true
    SReplay.restart()

    assert(SReplay.recording.user_data is Dictionary)
    @warning_ignore("unsafe_call_argument")
    _set_current_state(SReplay.recording.user_data, true)

func _step_forward() -> void:
    SReplay.playback_rate = SReplay.Rate.FULL
    get_tree().paused = false
    await get_tree().physics_frame
    get_tree().paused = true
    SReplay.playback_rate = SReplay.Rate.PAUSED

func _step_backward() -> void:
    if SReplay.current_tick == 0 or SReplay.shift_finished.is_connected(_on_step_shift_finished):
        return

    get_tree().paused = false
    SReplay.shift_finished.connect(_on_step_shift_finished, CONNECT_ONE_SHOT)
    SReplay.shift(SReplay.current_tick - 2, true)

func _on_step_shift_finished() -> void:
    get_tree().paused = true

func _toggle_group_button_toggled(
    on: bool,
    button: Button,
    others: Array[Button],
    rate: SReplay.Rate
) -> void:
    if !on:
        button.set_pressed_no_signal(true)
        return

    for other in others:
        other.set_pressed_no_signal(false)

    _speed_control = rate
    if SReplay.playback_rate != SReplay.Rate.PAUSED:
        SReplay.playback_rate = _speed_control
        Engine.time_scale = _speed_control / float(SReplay.Rate.FULL)
        pass

func _quarter_speed_toggled(on: bool) -> void:
    @warning_ignore("unsafe_call_argument")
    _toggle_group_button_toggled(on, %QuarterSpeed, [%HalfSpeed, %FullSpeed, %DoubleSpeed], SReplay.Rate.QUARTER)

func _half_speed_toggled(on: bool) -> void:
    @warning_ignore("unsafe_call_argument")
    _toggle_group_button_toggled(on, %HalfSpeed, [%QuarterSpeed, %FullSpeed, %DoubleSpeed], SReplay.Rate.HALF)

func _full_speed_toggled(on: bool) -> void:
    @warning_ignore("unsafe_call_argument")
    _toggle_group_button_toggled(on, %FullSpeed, [%HalfSpeed, %QuarterSpeed, %DoubleSpeed], SReplay.Rate.FULL)

func _double_speed_toggled(on: bool) -> void:
    @warning_ignore("unsafe_call_argument")
    _toggle_group_button_toggled(on, %DoubleSpeed, [%HalfSpeed, %FullSpeed, %QuarterSpeed], SReplay.Rate.DOUBLE)

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

    if SReplay.mode == SReplay.Mode.REPLAYING && !_scrubber_dragging:
        _scrubber.set_value_no_signal(SReplay.current_tick)
        _scrubber.tooltip_text = str(SReplay.current_tick)

func _on_scrubber_drag_started() -> void:
    _scrubber_dragging = true

func _on_scrubber_drag_ended(value_changed: bool) -> void:
    _scrubber_dragging = false
    if !value_changed or SReplay.mode != SReplay.Mode.REPLAYING:
        return

    SReplay.shift(roundi(_scrubber.value), false)
