extends Control

@onready var _recording_label: Label = %RecordingLabel
@onready var _replaying_label: Label = %ReplayingLabel

@onready var _playback_control: Control = %PlaybackContainer
@onready var _scrubber: HSlider = %Scrubber
@onready var _all_buttons: Array[Node] = %PlaybackContainer.find_children("*", "Button")
var _scrubber_dragging: bool = false

var _font_color: Color = Color.WHITE
var _font_outline_color: Color = Color.BLACK
var _time: float = 0

var _speed_control: SReplay.Rate = SReplay.Rate.FULL

func _get_current_state() -> Dictionary:
    var player: Player = get_tree().get_first_node_in_group("player")
    var tracked_bodies := get_tree().get_nodes_in_group("tracked_bodies")
    var body_data: Array[Dictionary] = []
    for node in tracked_bodies:
        assert(node is RigidBody3D)
        @warning_ignore("unsafe_cast")
        var body: RigidBody3D = node
        body_data.append({
            "path": body.get_path(),
            "position": var_to_str(body.global_position),
            "rotation": var_to_str(body.global_basis),
            "linear_velocity": var_to_str(body.linear_velocity),
            "angular_velocity": var_to_str(body.angular_velocity)
        })
    return {
        "scene_path": get_tree().current_scene.scene_file_path,
        "player": player.to_state_dict(),
        "body_data": body_data,
    }

func _set_current_state(state: Dictionary, always_change_scene: bool) -> void:
    var scene_path: String = state["scene_path"]
    var player_state: Dictionary = state["player"]
    var body_data: Array = state["body_data"]
    
    var tree: SceneTree = get_tree()
    if always_change_scene or (tree.current_scene and tree.current_scene.scene_file_path != scene_path):
        var scene: PackedScene = load(scene_path)
        assert(tree.change_scene_to_packed(scene) == OK)
        await tree.process_frame
        await tree.process_frame
    
    for body: Dictionary in body_data:
        var path: String = body["path"]
        @warning_ignore_start("unsafe_cast", "unsafe_call_argument")
        var body_pos: Vector3 = str_to_var(body["position"])
        var bod_rot: Basis = str_to_var(body["rotation"])
        var linear_velocity: Vector3 = str_to_var(body["linear_velocity"])
        var angular_velocity: Vector3 = str_to_var(body["angular_velocity"])
        @warning_ignore_restore("unsafe_cast", "unsafe_call_argument")
        
        var node: RigidBody3D = get_node(path)
        if !node:
            continue

        node.position = body_pos
        node.global_basis = bod_rot
        node.linear_velocity = linear_velocity
        node.angular_velocity = angular_velocity
    
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
    
    assert(SReplay.recording.user_data is Dictionary)
    @warning_ignore("unsafe_call_argument")
    _set_current_state(SReplay.recording.user_data, true)

    # playing on the idle frame is undefined behaviour
    await get_tree().physics_frame
    await get_tree().physics_frame
    
    _scrubber.max_value = SReplay.recording.max_tick

    SReplay.playback_rate = _speed_control
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

func _command_unpause() -> void:
    SReplay.playback_rate = _speed_control

func _play_toggle_pressed() -> void:
    if SReplay.playback_rate == SReplay.Rate.PAUSED:
        SReplay.playback_rate = _speed_control
    else:
        SReplay.playback_rate = SReplay.Rate.PAUSED

func _restart() -> void:
    SReplay.playback_rate = SReplay.Rate.PAUSED
    SReplay.restart()

    assert(SReplay.recording.user_data is Dictionary)
    @warning_ignore("unsafe_call_argument")
    _set_current_state(SReplay.recording.user_data, true)

func _step_forward() -> void:

    _disable_controls()
    SReplay.playback_rate = SReplay.Rate.PAUSED
    SReplay.seek(SReplay.current_tick + 1, true)

func _step_backward() -> void:
    if SReplay.current_tick == 0:
        return

    _disable_controls()
    SReplay.playback_rate = SReplay.Rate.PAUSED
    SReplay.seek(SReplay.current_tick - 1, true)

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

func _disable_controls() -> void:
    for button: Button in _all_buttons:
        button.disabled = true
    
    _scrubber.editable = false

func _enable_controls() -> void:
    for button: Button in _all_buttons:
        button.disabled = false
    
    _scrubber.editable = true

func _sreplay_mode_changed(_old: SReplay.Mode, new: SReplay.Mode) -> void:
    if new != SReplay.Mode.REPLAYING:
        _playback_control.visible = false

func _sreplay_seek_finished() -> void:
    _enable_controls()

func _sreplay_playback_rate_changed(old: int, new: int) -> void:
    if new == SReplay.Rate.PAUSED:
        get_tree().paused = true
        Engine.time_scale = 1.0
        return
        
    if old == SReplay.Rate.PAUSED:
        get_tree().paused = false

    if new != SReplay.Rate.PAUSED:
        Engine.time_scale = new / float(SReplay.Rate.FULL)

func _ready() -> void:
    Console.add_command("record", _command_record, [], 0, "Begin recording a replay, if we're not already recording one")
    Console.add_command("stop", _command_stop, [], 0, "Stop recording a replay")
    Console.add_command("play", _command_play, [], 0, "Playback the currently loaded replay")
    Console.add_command("save", _command_save, ["Replay Name"], 1, "Save the recorded replay to a file")
    Console.add_command("load", _command_load, ["Replay Name"], 1, "Load a replay from a file")
    Console.add_command("pause", _command_pause, [], 0, "Pause replay")
    Console.add_command("unpause", _command_unpause, [], 0, "Unpause replay")
    
    SReplay.mode_changed.connect(_sreplay_mode_changed)
    SReplay.seek_finished.connect(_sreplay_seek_finished)
    SReplay.playback_rate_changed.connect(_sreplay_playback_rate_changed)

func _unhandled_input(event: InputEvent) -> void:
    if SReplay.mode != SReplay.Mode.REPLAYING:
        return

    if !event.is_action_pressed(&"toggle_replay_ui"):
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
    
    _recording_label.add_theme_color_override(&"font_color", _font_color)
    _recording_label.add_theme_color_override(&"font_outline_color", _font_outline_color)
    _replaying_label.add_theme_color_override(&"font_color", _font_color)
    _replaying_label.add_theme_color_override(&"font_outline_color", _font_outline_color)

    if SReplay.mode == SReplay.Mode.REPLAYING && !_scrubber_dragging:
        _scrubber.set_value_no_signal(SReplay.current_tick)
        _scrubber.tooltip_text = str(SReplay.current_tick)

func _physics_process(_delta: float) -> void:
    for node: Node in get_tree().get_nodes_in_group(""):
        assert(node is RigidBody3D)
        @warning_ignore("unsafe_cast")
        var body: RigidBody3D = node
        var path := str(body.get_path())
        body.global_position = SReplay.capture("position" + path, body.global_position)
        body.global_basis = SReplay.capture("basis" + path, body.global_basis)
        body.linear_velocity = SReplay.capture("linear" + path, body.linear_velocity)
        body.angular_velocity = SReplay.capture("angular" + path, body.angular_velocity)

func _on_scrubber_drag_started() -> void:
    _scrubber_dragging = true

func _on_scrubber_drag_ended(value_changed: bool) -> void:
    _scrubber_dragging = false
    if !value_changed or SReplay.mode != SReplay.Mode.REPLAYING:
        return

    _disable_controls()
    SReplay.playback_rate = SReplay.Rate.PAUSED
    SReplay.seek(roundi(_scrubber.value), true)
