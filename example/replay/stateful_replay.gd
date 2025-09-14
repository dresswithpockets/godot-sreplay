extends Node

class Recording extends RefCounted:
    var input_periods: Array[InputPeriod] = []

class InputPeriod extends RefCounted:
    var time: float = 0
    var action_states: ActionStates = ActionStates.new()
    var mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE
    
    static func from_empty(from_time: float) -> InputPeriod:
        var new := InputPeriod.new()
        new.time = from_time
        return new
    
    static func from_input(from_time: float) -> InputPeriod:
        var new := InputPeriod.new()
        new.time = from_time

        for action in InputMap.get_actions():
            if action.begins_with("ui_"):
                continue

            var not_exact := ActionState.from_input(action, false)
            var exact := ActionState.from_input(action, true)
            new.action_states.states[action] = ActionMatchPair.new(not_exact, exact)
        
        new.mouse_mode = Input.mouse_mode
        return new
    
    func equivelent(other: InputPeriod) -> bool:
        return mouse_mode == other.mouse_mode and action_states.equivelent(other.action_states)

class ActionStates extends RefCounted:
    var states: Dictionary[StringName, ActionMatchPair] = {}
    
    func equivelent(other: ActionStates) -> bool:
        if len(states) != len(other.states):
            return false

        for action in states:
            var other_state = other.states.get(action)
            if other_state == null:
                return false

            var state := states[action]
            if !state.equivelent(other_state):
                return false
        
        return true

class ActionMatchPair extends RefCounted:
    var not_exact_match: ActionState
    var exact_match: ActionState
    
    func _init(not_exact: ActionState, exact: ActionState) -> void:
        not_exact_match = not_exact
        exact_match = exact
    
    func equivelent(other: ActionMatchPair) -> bool:
        return not_exact_match.equivelent(other.not_exact_match) and \
            exact_match.equivelent(other.exact_match)

class ActionState extends RefCounted:
    var just_pressed: bool
    var just_released: bool
    var pressed: bool
    var raw_strength: float
    var strength: float
    
    static func from_input(action: StringName, exact_match: bool) -> ActionState:
        var new := ActionState.new()
        new.just_pressed = Input.is_action_just_pressed(action, exact_match)
        new.just_released = Input.is_action_just_released(action, exact_match)
        new.pressed = Input.is_action_pressed(action, exact_match)
        new.raw_strength = Input.get_action_raw_strength(action, exact_match)
        new.strength = Input.get_action_strength(action, exact_match)
        return new
    
    func equivelent(other: ActionState) -> bool:
        return just_pressed == other.just_pressed and \
            just_released == other.just_released and \
            pressed == other.pressed and \
            raw_strength == other.raw_strength and \
            strength == other.strength

enum Mode { OFF, RECORDING, REPLAYING }
var _mode: Mode = Mode.OFF

var recording: Recording = Recording.new()
var _current_time: float = 0
var _current_period_idx: int = 0
var _start_tick_usec: int
var _current_tick_usec: int

func record_forward(_max_ticks: int = -1) -> void:
    if _mode != Mode.OFF:
        return

    # TODO: _max_ticks
    recording = Recording.new()
    _current_time = 0
    _current_period_idx = 0
    _start_tick_usec = Time.get_ticks_usec()
    _current_tick_usec = Time.get_ticks_usec()
    _mode = Mode.RECORDING

func stop() -> void:
    if _mode == Mode.RECORDING:
        _record_action_states(InputPeriod.from_empty(_current_time))

    _mode = Mode.OFF

func playback() -> void:
    if _mode != Mode.OFF:
        return

    _current_time = 0
    _current_period_idx = 0
    _start_tick_usec = Time.get_ticks_usec()
    _current_tick_usec = Time.get_ticks_usec()
    _mode = Mode.REPLAYING

func _record_action_states(period: InputPeriod) -> void:
    var last_idx = len(recording.input_periods) - 1
    if last_idx == -1 or !recording.input_periods[last_idx].equivelent(period):
        recording.input_periods.push_back(period)

func _next_period() -> InputPeriod:
    if _current_period_idx >= len(recording.input_periods) - 1:
        return null

    return recording.input_periods[_current_period_idx]

func _current_period() -> InputPeriod:
    return recording.input_periods[_current_period_idx]

func _physics_process(delta: float) -> void:
    match _mode:
        Mode.RECORDING:
            _record_action_states(InputPeriod.from_input(_current_time))
            _current_time += delta
        Mode.REPLAYING:
            _current_time += delta
            var next := _next_period()
            while next != null and next.time <= _current_time:
                _current_period_idx += 1
                next = _next_period()
            
            if next == null:
                stop()

func get_action_raw_strength(action: StringName, exact_match: bool = false) -> float:
    match _mode:
        Mode.REPLAYING:
            var state: ActionMatchPair = _current_period().action_states.states[action]
            if exact_match:
                return state.exact_match.raw_strength
            return state.not_exact_match.raw_strength

    return Input.get_action_raw_strength(action, exact_match)

func get_action_strength(action: StringName, exact_match: bool = false) -> float:
    match _mode:
        Mode.REPLAYING:
            var state: ActionMatchPair = _current_period().action_states.states[action]
            if exact_match:
                return state.exact_match.strength
            return state.not_exact_match.strength

    return Input.get_action_strength(action, exact_match)

func is_action_just_pressed(action: StringName, exact_match: bool = false) -> bool:
    match _mode:
        Mode.REPLAYING:
            var state: ActionMatchPair = _current_period().action_states.states[action]
            if exact_match:
                return state.exact_match.just_pressed
            return state.not_exact_match.just_pressed

    return Input.is_action_just_pressed(action, exact_match)

func is_action_just_released(action: StringName, exact_match: bool = false) -> bool:
    match _mode:
        Mode.REPLAYING:
            var state: ActionMatchPair = _current_period().action_states.states[action]
            if exact_match:
                return state.exact_match.just_released
            return state.not_exact_match.just_released

    return Input.is_action_just_released(action, exact_match)

func is_action_pressed(action: StringName, exact_match: bool = false) -> bool:
    match _mode:
        Mode.REPLAYING:
            var state: ActionMatchPair = _current_period().action_states.states[action]
            if exact_match:
                return state.exact_match.pressed
            return state.not_exact_match.pressed

    return Input.is_action_pressed(action, exact_match)

func get_axis(negative_action: StringName, positive_action: StringName) -> float:
    return get_action_strength(positive_action) - get_action_strength(negative_action)

func get_mouse_mode() -> Input.MouseMode:
    if _mode == Mode.REPLAYING:
        return _current_period().mouse_mode

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
