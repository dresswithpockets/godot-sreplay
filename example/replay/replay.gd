extends Node

class RingBuffer extends RefCounted:
    var buffer: Array = []
    var start: int = 0
    var end: int = 0
    var size: int = 0

    func _init(capacity: int) -> void:
        buffer.resize(capacity)

    func push(item) -> void:
        buffer[end] = item
        end += 1
        if end == buffer.size():
            end = 0

        if size == buffer.size():
            start = end
        else:
            size += 1
    
    func to_array() -> Array:
        var array: Array = []
        array.append_array(_array_one())
        array.append_array(_array_two())
        return array

    func _array_one() -> Array:
        if size == 0:
            return []
        if start < end:
            return buffer.slice(start, end)
        return buffer.slice(start)
    
    func _array_two() -> Array:
        if size == 0 or start < end:
            return []
        return buffer.slice(0, end)

class ReplayDemo extends RefCounted:
    var snapshots: Dictionary[StringName, Array] = {}
    var input_events: Array[TimedInputEvent] = []
    var raw_strength_states: Dictionary[StringName, Array] = {}
    var strength_states: Dictionary[StringName, Array] = {}
    var just_pressed_states: Dictionary[StringName, Array] = {}
    var just_released_states: Dictionary[StringName, Array] = {}
    var pressed_states: Dictionary[StringName, Array] = {}
    var mouse_mode_states: Array = []
    
    func duplicate() -> ReplayDemo:
        var demo := ReplayDemo.new()
        demo.snapshots = snapshots.duplicate(true)
        demo.input_events = input_events.duplicate(true)
        demo.raw_strength_states = raw_strength_states.duplicate(true)
        demo.strength_states = strength_states.duplicate(true)
        demo.just_pressed_states = just_pressed_states.duplicate(true)
        demo.just_released_states = just_released_states.duplicate(true)
        demo.pressed_states = pressed_states.duplicate(true)
        demo.mouse_mode_states = mouse_mode_states.duplicate(true)
        return demo
    
    func is_empty() -> bool:
        for value in snapshots.values():
            if len(value) > 0:
                return false
        
        if len(input_events) > 0:
            return false
        
        for value in raw_strength_states.values():
            if len(value) > 0:
                return false
        
        for value in strength_states.values():
            if len(value) > 0:
                return false
        
        for value in just_pressed_states.values():
            if len(value) > 0:
                return false
        
        for value in just_released_states.values():
            if len(value) > 0:
                return false
        
        for value in pressed_states.values():
            if len(value) > 0:
                return false
        
        if len(mouse_mode_states) > 0:
            return false
        
        return true

class TimedInputEvent extends RefCounted:
    var ticks_usec: int
    var input_event: InputEvent

enum Mode { OFF, RECORDING, REPLAYING }
var _mode: Mode = Mode.OFF

var current_demo: ReplayDemo = ReplayDemo.new()

var _start_tick_usec: int
var _current_tick_usec: int

func record_buffered(_ticks: int = 1800) -> void:
    if _mode != Mode.OFF:
        return

    # TODO: buffered replay
    pass

func record_forward(_max_ticks: int = -1) -> void:
    if _mode != Mode.OFF:
        return

    # TODO: _max_ticks
    current_demo = ReplayDemo.new()
    _start_tick_usec = Time.get_ticks_usec()
    _current_tick_usec = Time.get_ticks_usec()
    _mode = Mode.RECORDING

func stop() -> void:
    if _mode != Mode.RECORDING:
        return

    _mode = Mode.OFF

func playback() -> void:
    if _mode != Mode.OFF:
        return

    assert(get_tree().reload_current_scene() == OK)

    _start_tick_usec = Time.get_ticks_usec()
    _current_tick_usec = Time.get_ticks_usec()
    _mode = Mode.REPLAYING

func snapshot(key: StringName, value: Variant) -> Variant:
    match _mode:
        Mode.RECORDING:
            if Engine.is_in_physics_frame():
                current_demo.snapshots.get_or_add(key, []).push_back(value)
            return value
        Mode.REPLAYING:
            if Engine.is_in_physics_frame():
                var values: Array = current_demo.snapshots.get(key)
                if values:
                    return values.pop_front()

    return value

func _input(event: InputEvent) -> void:
    if _mode != Mode.RECORDING:
        return

    var pair := TimedInputEvent.new()
    pair.ticks_usec = _current_tick_usec - _start_tick_usec
    pair.input_event = event
    current_demo.input_events.push_back(pair)

func _process(_delta: float) -> void:
    _current_tick_usec = Time.get_ticks_usec()

    # replay input events over time
    if _mode == Mode.REPLAYING:
        var playback_tick := _current_tick_usec - _start_tick_usec
        while len(current_demo.input_events) > 0 and current_demo.input_events[0].ticks_usec <= playback_tick:
            var event_pair: TimedInputEvent = current_demo.input_events.pop_front()
            Input.parse_input_event(event_pair.input_event)

func _physics_process(_delta: float) -> void:
    if current_demo.is_empty():
        _mode = Mode.OFF

func _handle_action_state(
    action: StringName,
    exact_match: bool,
    input_func: Callable,
    states_dict: Dictionary[StringName, Array]
) -> Variant:
    match _mode:
        Mode.RECORDING:
            var value = input_func.call(action, exact_match)
            if Engine.is_in_physics_frame():
                states_dict.get_or_add(action, []).push_back(value)
            return value
        Mode.REPLAYING:
            if Engine.is_in_physics_frame():
                var values: Array = states_dict.get(action)
                if values:
                    return values.pop_front()

            return 0
        _:
            return input_func.call(action, exact_match)

func get_action_raw_strength(action: StringName, exact_match: bool = false) -> float:
    return _handle_action_state(action, exact_match, Input.get_action_raw_strength, current_demo.raw_strength_states)

func get_action_strength(action: StringName, exact_match: bool = false) -> float:
    return _handle_action_state(action, exact_match, Input.get_action_strength, current_demo.strength_states)

func is_action_just_pressed(action: StringName, exact_match: bool = false) -> bool:
    return _handle_action_state(action, exact_match, Input.is_action_just_pressed, current_demo.just_pressed_states)

func is_action_just_released(action: StringName, exact_match: bool = false) -> bool:
    return _handle_action_state(action, exact_match, Input.is_action_just_released, current_demo.just_released_states)

func is_action_pressed(action: StringName, exact_match: bool = false) -> bool:
    return _handle_action_state(action, exact_match, Input.is_action_pressed, current_demo.pressed_states)

func get_axis(negative_action: StringName, positive_action: StringName) -> float:
    return get_action_strength(positive_action) - get_action_strength(negative_action)

func get_mouse_mode() -> Input.MouseMode:
    match _mode:
        Mode.RECORDING:
            var value = Input.mouse_mode
            if Engine.is_in_physics_frame():
                current_demo.mouse_mode_states.push_back(value)
            return value
        Mode.REPLAYING:
            if Engine.is_in_physics_frame():
                return current_demo.mouse_mode_states.pop_front()

            if len(current_demo.mouse_mode_states) > 0:
                return current_demo.mouse_mode_states[0]
            
            return Input.MOUSE_MODE_CAPTURED
        _:
            return Input.mouse_mode

func get_vector(
    negative_x: StringName,
    positive_x: StringName,
    negative_y: StringName,
    positive_y: StringName,
    deadzone: float = -1.0
) -> Vector2:
    # based on godot's Input.get_vector
    var vector := Vector2(
        get_action_raw_strength(positive_x) - get_action_raw_strength(negative_x),
        get_action_raw_strength(positive_y) - get_action_raw_strength(negative_y)
    )
    
    if deadzone < 0:
        var deadzone_sum := InputMap.action_get_deadzone(negative_x) + \
                            InputMap.action_get_deadzone(positive_x) + \
                            InputMap.action_get_deadzone(negative_y) + \
                            InputMap.action_get_deadzone(positive_y)
        deadzone = 0.25 * deadzone_sum

    var length := vector.length()
    if length <= deadzone:
        return Vector2.ZERO
    
    if length > 1.0:
        return vector / length
    
    return vector * inverse_lerp(deadzone, 1, length) / length
