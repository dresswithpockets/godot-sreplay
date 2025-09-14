extends Control

@onready var _recording_label: Label = $OverlayContainer/RecordingLabel
var _font_color: Color = Color.WHITE
var _font_outline_color: Color = Color.BLACK
var _time: float = 0

func _record() -> void:
    if SReplay.mode != SReplay.Mode.OFF:
        Console.print_error("Already recording a replay")
        return
    
    # recording on the idle frame is undefined behaviour
    await get_tree().physics_frame
    SReplay.record()
    Console.print_info("Recording...")

func _stop() -> void:
    if SReplay.mode == SReplay.Mode.OFF:
        Console.print_error("Not currently recording or replaying anything")
        return
    
    Input.use_accumulated_input = false
    SReplay.stop()
    Console.print_info("Stopped recording.")

func _play() -> void:
    if SReplay.mode != SReplay.Mode.OFF:
        Console.print_error("Already recording or playing a replay")
        return

    assert(get_tree().reload_current_scene() == OK)

    # playing on the idle frame is undefined behaviour
    await get_tree().physics_frame
    Input.use_accumulated_input = false
    SReplay.play()
    Console.print_info("Playing...")

func _save(path: String) -> void:
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

func _load(path: String) -> void:
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

func _pause() -> void:
    await get_tree().physics_frame
    Engine.time_scale = 0.0

func _unpause() -> void:
    await get_tree().physics_frame
    Engine.time_scale = 1.0

func _ready() -> void:
    Console.add_command("record", _record, [], 0, "Begin recording a replay, if we're not already recording one")
    Console.add_command("stop", _stop, [], 0, "Stop recording a replay")
    Console.add_command("play", _play, [], 0, "Playback the currently loaded replay")
    Console.add_command("save", _save, ["Replay Name"], 1, "Save the recorded replay to a file")
    Console.add_command("load", _load, ["Replay Name"], 1, "Load a replay from a file")
    Console.add_command("pause", _pause, [], 0, "Pause replay")
    Console.add_command("unpause", _unpause, [], 0, "Unpause replay")

#func _input(event: InputEvent) -> void:
    #if event is InputEventKey and event.is_pressed():
#
        #if event.keycode == KEY_P:
            #await get_tree().physics_frame
            #SReplay.record()
            #return
#
        #if event.keycode == KEY_O:
            #await get_tree().physics_frame
            #SReplay.stop()
            #return
        #
        #if event.keycode == KEY_I:
            #assert(get_tree().reload_current_scene() == OK)
            #await get_tree().physics_frame
            #
            #SReplay.play()
            #
            #await get_tree().physics_frame
            #Engine.time_scale = 0.5
#
            #return

func _process(delta: float) -> void:
    if SReplay.mode == SReplay.Mode.RECORDING:
        _time += delta
        _font_color.a = pingpong(_time, 1.0)
        _font_outline_color.a = pingpong(_time, 1.0)
    else:
        _font_color.a = 0
        _font_outline_color.a = 0

    _recording_label.add_theme_color_override("font_color", _font_color)
    _recording_label.add_theme_color_override("font_outline_color", _font_outline_color)

#func _physics_process(delta: float) -> void:
    #if SReplay.mode != SReplay.Mode.OFF:
        #return
#
    #if Input.is_action_just_pressed("sreplay_record"):
        #pass
#
    #if Input.is_action_just_pressed("sreplay_stop"):
        #pass
