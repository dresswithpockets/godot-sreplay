## Record input and node states into a replay, for future playback.
##
## Wraps calls to [Input] to capture input and provide a drop-in replacement for replay playback.
extends Node

enum Mode {
    OFF, ## No replay is being recorded or played back
    RECORDING, ## SReplay is recording a replay
    REPLAYING, ## SReplay is playing back a replay
}
var _mode: Mode = Mode.OFF

## the current state of sreplay. See [method record], [method stop], and [method play].
var mode: Mode:
    get:
        return _mode

static func _is_compatible_input_event(event: InputEvent) -> bool:
    # for security reasons, SReplay enforces that the InputEvent is one of a specified number of
    # types. Custom InputEvents would need to be added to this list and the list below
    return event is InputEventMouseButton or \
       event is InputEventMouseMotion or \
       event is InputEventShortcut or \
       event is InputEventScreenTouch or \
       event is InputEventScreenDrag or \
       event is InputEventPanGesture or \
       event is InputEventMIDI or \
       event is InputEventMagnifyGesture or \
       event is InputEventKey or \
       event is InputEventJoypadMotion or \
       event is InputEventJoypadButton or \
       event is InputEventAction

const _compatible_input_event_class_names: Array[String] = [
    "InputEventMouseButton",
    "InputEventMouseMotion",
    "InputEventShortcut",
    "InputEventScreenTouch",
    "InputEventScreenDrag",
    "InputEventPanGesture",
    "InputEventMIDI",
    "InputEventMagnifyGesture",
    "InputEventKey",
    "InputEventJoypadMotion",
    "InputEventJoypadButton",
    "InputEventAction",
]

static func _is_compatible_input_event_class_name(event_class_name: String) -> bool:
    return event_class_name in _compatible_input_event_class_names

static func _instantiate_compatible_input_event(event_class_name: String) -> InputEvent:
    if !_is_compatible_input_event_class_name(event_class_name):
        push_error("input event class '%s' is not compatible with SReplay" % event_class_name)
        return null
    
    return ClassDB.instantiate(event_class_name)

## Begin recording a new replay. [br][br]
##
## SReplay will assign a new [member Recording] to [member recording], which will contain the replay.
##
## By default, this will record an arbitrarily-long replay until stop is called. However, if 
## [param length] is greater than 0, then the recording will be created in buffered mode. After 
## [param length]-seconds have passed in the recording, then the beginning of the replay will be
## trimmed to keep the recording at [param length]-seconds in length. [br][br]
##
## Calls to [Input] differ in behaviour between physics and idle ticks. Replays occasionally take 
## full snapshots of the entire input state on idle ticks and on physics ticks, in order to enable 
## bidirectional navigation of the replay during playback. You can control how frequently snapshots
## are captured by varying [param idle_snapshot_period] and [param physics_snapshot_period],
## which specify the amount of time between each snapshot.
func record(
    length: int = 0,
    idle_snapshot_period: float = 1.0,
    physics_snapshot_period: float = 1.0,
) -> void:
    # TODO: record during playback to "edit" the recording?
    if _mode != Mode.OFF:
        push_error("attempted to record while recording or replaying a replay")
        return
    
    _mode = Mode.RECORDING
    _reset()
    # TODO: support specifying length in Recording to trim the head of the recording as time exceeds the length
    recording = Recording.new(idle_snapshot_period, physics_snapshot_period)

## Stops recording a replay. [br][br]
##
## Access the replay from [member recording].
func stop() -> void:
    _reset()
    _mode = Mode.OFF

## begins replaying the replay from the replay property. Errors if [member mode] is not 
## [constant Mode.OFF]; that is, if a replay is being recorded or played back.
func play() -> void:
    if _mode != Mode.OFF:
        push_error("attempted to play while already recording or replaying a replay")
        return

    if recording == null:
        push_error("attempting to play null recording")
        return
    
    if recording.is_empty():
        push_error("attempting to play empty recording")
        return
    
    _reset()
    _mode = Mode.REPLAYING


# used to tag that an InputEvent was sent via replay payback. Necessary for filtering out 
# non-playback InputEvents during playback.
const _replay_event_meta_key: StringName = &"replay_input_event"
const _replay_ignore_meta_key: StringName = &"replay_ignore_event"

enum _DeltaKey {
    Actions_JustPressed,
    Actions_JustReleased,
    Actions_Pressed,
    Actions_RawStrength,
    Actions_Strength,
    ActionsExact_JustPressed,
    ActionsExact_JustReleased,
    ActionsExact_Pressed,
    ActionsExact_RawStrength,
    ActionsExact_Strength,
    MouseMode,
    LastMouseScreenVelocity,
    LastMouseVelocity,
    MouseButtonMask,
    Captures,
}

static func _map_dict_values(from: Dictionary, callable: Callable) -> Dictionary:
    var result = {}
    for key in from:
        result[key] = callable.call(from)
    return result

static func _serialize_capture(from: Variant) -> Variant:
    if typeof(from) == TYPE_OBJECT:
        pass

    return from

class DeltaChange extends RefCounted:
    var type: int

class ActionChange extends DeltaChange:
    var name: StringName
    var value: Variant
    
    func _init(p_name: StringName, p_value: Variant):
        name = p_name
        value = p_value
    
    static func to_dict(from: ActionChange) -> Dictionary:
        return {
            "name": from.name,
            "value": from.value,
        }
    
    static func from_dict(from: Dictionary) -> ActionChange:
        return ActionChange.new(from["name"], from["value"])

class Delta extends RefCounted:
    var time: float
    # if Actions key, then the value is Array[ActionChange]
    var changes: Dictionary[_DeltaKey, Variant]
    
    static func to_dict(delta: Delta) -> Dictionary:
        var changes: Dictionary[String, Variant] = {}
        var delta_keys := _DeltaKey.keys()
        for old_key in delta.changes:
            var new_key: String = delta_keys[old_key]
            var value: Variant = delta.changes[old_key]
            if new_key.begins_with("Actions"):
                changes[new_key] = value.map(ActionChange.to_dict)
                continue
            
            changes[new_key] = var_to_str(delta.changes[old_key])

        return {
            "time": delta.time,
            "changes": changes,
        }
    
    static func from_dict(from: Dictionary) -> Delta:
        var delta := Delta.new()
        delta.time = from["time"]
        delta.changes = {}
        var changes := from["changes"] as Dictionary
        for change in changes:
            var key: _DeltaKey = _DeltaKey[change]
            if change.begins_with("Actions"):
                delta.changes[key] = changes[change].map(ActionChange.from_dict)
            else:
                delta.changes[key] = str_to_var(changes[change])
        return delta

class TimedInputEvents extends RefCounted:
    var time: float
    var events: Array[InputEvent]
    
    func _init(p_time: float, p_events: Array[InputEvent]) -> void:
        time = p_time
        events = p_events

    static func _event_to_dict(event: InputEvent) -> Dictionary:
        var properties: Dictionary[String, Variant] = {}
        for property in event.get_property_list():
            if (property["usage"] & PROPERTY_USAGE_STORAGE) != PROPERTY_USAGE_STORAGE:
                continue
            
            var name: String = property["name"]
            properties[name] = event.get(name)

        return {
            "class": event.get_class(),
            "properties": var_to_str(properties),
        }
    
    static func to_dict(from: TimedInputEvents) -> Dictionary:
        return {
            "time": from.time,
            "events": from.events.map(_event_to_dict),
        }
    
    static func _event_from_dict(from: Dictionary) -> InputEvent:
        var event_class: String = from["class"]
        if event_class not in _compatible_input_event_class_names:
            push_error("Cannot instantiate InputEvent from class '%s' because it is not compatible with SReplay" % event_class)
            return null
        
        var event: InputEvent = ClassDB.instantiate(event_class)
        
        var properties: Dictionary = str_to_var(from["properties"])
        for property in properties:
            event.set(property, properties[property])
        
        return event
    
    static func from_dict(dict: Dictionary) -> TimedInputEvents:
        var time: float = dict["time"]
        var events: Array = dict["events"]
        var mapped_events: Array[InputEvent] = []
        mapped_events.assign(events.map(_event_from_dict))
        return TimedInputEvents.new(time, mapped_events)

class ActionState extends RefCounted:
    var raw_strength: float
    var strength: float
    var just_pressed: bool
    var just_released: bool
    var pressed: bool
    
    func duplicate() -> ActionState:
        var new := ActionState.new()
        new.raw_string = raw_strength
        new.strength = strength
        new.just_pressed = just_pressed
        new.just_released = just_released
        new.pressed = pressed
        return new
    
    static func to_dict(from: ActionState) -> Dictionary:
        return {
            "raw_strength": from.raw_strength,
            "strength": from.strength,
            "just_pressed": from.just_pressed,
            "just_released": from.just_released,
            "pressed": from.pressed,
        }
    
    static func from_dict(from: Dictionary) -> ActionState:
        var new := ActionState.new()
        new.raw_string = from["raw_strength"]
        new.strength = from["strength"]
        new.just_pressed = from["just_pressed"]
        new.just_released = from["just_released"]
        new.pressed = from["pressed"]
        return new

## the cumulative input state during recording and playback
class InputState extends RefCounted:
    ## maps the action name to a dictionary mapping an input key to a value
    var actions: Dictionary[StringName, ActionState] = {}
    ## maps the action name (with exact_match=true) to a dictionary mapping an input key to a value
    var actions_exact: Dictionary[StringName, ActionState] = {}
    var mouse_mode: Input.MouseMode
    var last_mouse_screen_velocity: Vector2
    var last_mouse_velocity: Vector2
    var mouse_button_mask: int
    ## maps an arbitrary string name to a captured value. Can be any variant supplied by a user
    var captures: Dictionary[StringName, Variant] = {}
    
    func _init(
        p_actions: Dictionary[StringName, ActionState] = {},
        p_actions_exact: Dictionary[StringName, ActionState] = {},
        p_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE,
        p_last_mouse_screen_velocity: Vector2 = Vector2.ZERO,
        p_last_mouse_velocity: Vector2 = Vector2.ZERO,
        p_mouse_button_mask: int = 0,
        p_captures: Dictionary[StringName, Variant] = {},
    ) -> void:
        actions = p_actions
        actions_exact = p_actions_exact
        mouse_mode = p_mouse_mode
        last_mouse_screen_velocity = p_last_mouse_screen_velocity
        last_mouse_velocity = p_last_mouse_velocity
        mouse_button_mask = p_mouse_button_mask
        captures = p_captures
    
    static func to_dict(from: InputState) -> Dictionary:
        return {
            "actions": SReplay._map_dict_values(from.actions, ActionState.to_dict),
            "actions_exact": SReplay._map_dict_values(from.actions_exact, ActionState.to_dict),
            "mouse_mode": from.mouse_mode,
            "last_mouse_screen_velocity": from.last_mouse_screen_velocity,
            "last_mouse_velocity": from.last_mouse_velocity,
            "mouse_button_mask": from.mouse_button_mask,
            "captures": from.captures,
        }
    
    static func from_dict(from: Dictionary) -> InputState:
        var actions: Dictionary[StringName, Dictionary] = from["actions"]
        var actions_exact: Dictionary[StringName, Dictionary] = from["actions_exact"]
        var mouse_mode: Input.MouseMode = from["mouse_mode"]
        var last_mouse_screen_velocity: Vector2 = from["last_mouse_screen_velocity"]
        var last_mouse_velocity: Vector2 = from["last_mouse_velocity"]
        var mouse_button_mask: int = from["mouse_button_mask"]
        var captures: Dictionary[StringName, Variant] = from["captures"]
        return InputState.new(
            SReplay._map_dict_values(actions, ActionState.from_dict),
            SReplay._map_dict_values(actions_exact, ActionState.from_dict),
            mouse_mode,
            last_mouse_screen_velocity,
            last_mouse_velocity,
            mouse_button_mask,
            captures,
        )
    
    func duplicate() -> InputState:
        var new_actions: Dictionary[StringName, ActionState] = {}
        for action in actions:
            new_actions[action] = actions[action].duplicate()
        
        var new_actions_exact: Dictionary[StringName, ActionState] = {}
        for action in actions_exact:
            new_actions_exact[action] = actions_exact[action].duplicate()
        
        return InputState.new(
            new_actions,
            new_actions_exact,
            mouse_mode,
            last_mouse_screen_velocity,
            last_mouse_velocity,
            mouse_button_mask,
            captures.duplicate(true)
        )

class Recording extends RefCounted:
    var idle_snapshot_delay := 1.0
    var physics_snapshot_delay := 1.0

    var idle_deltas: Array[Delta] = []
    var idle_input_snapshots: Array[InputState] = []
    var idle_input_events: Array[TimedInputEvents] = []
    var physics_deltas: Array[Delta] = []
    var physics_input_snapshots: Array[InputState] = []
    # TODO: Node state snapshotting

    func _init(p_idle_snapshot_delay: float, p_physics_snapshot_delay: float) -> void:
        idle_snapshot_delay = p_idle_snapshot_delay
        physics_snapshot_delay = p_physics_snapshot_delay
    
    func is_empty() -> bool:
        return idle_deltas.is_empty() and idle_input_snapshots.is_empty() and idle_input_events.is_empty() and physics_deltas.is_empty() and physics_input_snapshots.is_empty()
    
    func to_dict() -> Dictionary:
        return {
            "idle_snapshot_delay": idle_snapshot_delay,
            "physics_snapshot_delay": physics_snapshot_delay,

            "idle_deltas": idle_deltas.map(Delta.to_dict),
            "idle_input_snapshots": idle_input_snapshots.map(InputState.to_dict),
            "idle_input_events": idle_input_events.map(TimedInputEvents.to_dict),
            
            "physics_deltas": physics_deltas.map(Delta.to_dict),
            "physics_input_snapshots": physics_input_snapshots.map(InputState.to_dict)
        }
    
    static func from_dict(from: Dictionary) -> Recording:
        var idle_snapshot_delay: float = from["idle_snapshot_delay"]
        var physics_snapshot_delay: float = from["physics_snapshot_delay"]
        
        var idle_deltas: Array = from["idle_deltas"]
        var idle_input_snapshots: Array = from["idle_input_snapshots"]
        var idle_input_events: Array = from["idle_input_events"]
        
        var physics_deltas: Array = from["physics_deltas"]
        var physics_input_snapshots: Array = from["physics_input_snapshots"]
        
        var recording := Recording.new(idle_snapshot_delay, physics_snapshot_delay)
        recording.idle_deltas.assign(idle_deltas.map(Delta.from_dict))
        recording.idle_input_snapshots.assign(idle_input_snapshots.map(InputState.from_dict))
        recording.idle_input_events.assign(idle_input_events.map(TimedInputEvents.from_dict))
        
        recording.physics_deltas.assign(physics_deltas.map(Delta.from_dict))
        recording.physics_input_snapshots.assign(physics_input_snapshots.map(InputState.from_dict))
        return recording
    
    static func from_json(json: String) -> Recording:
        var dict: Dictionary = JSON.parse_string(json)
        var idle_snapshot_delay: float = dict["idle_snapshot_delay"]
        var physics_snapshot_delay: float = dict["physics_snapshot_delay"]
        var idle_deltas: Array[Dictionary] = dict["idle_deltas"]
        var idle_input_snapshots: Array[Dictionary] = dict["idle_input_snapshots"]
        var idle_input_events: Array[Dictionary] = dict["idle_input_events"]
        var physics_deltas: Array[Dictionary] = dict["physics_deltas"]
        var physics_input_snapshots: Array[Dictionary] = dict["physics_input_snapshots"]

        var recording := Recording.new(1.0, 1.0)
        for delta_dict in idle_deltas:
            var delta := Delta.new()
            delta.time = delta_dict["time"]
        return recording

var recording: Recording

# used in both recording and replaying mode
var _idle_time: float
var _idle_input: InputState = InputState.new()
var _idle_delta_idx: int = -1
var _idle_event_idx: int = -1
var _physics_time: float
var _physics_input: InputState = InputState.new()
var _physics_delta_idx: int = -1

# only used in recording mode
var _idle_last_snapshot_time: float
var _idle_delta: Delta = Delta.new()
var _physics_last_snapshot_time: float
var _physics_delta: Delta = Delta.new()

func _reset() -> void:
    _idle_time = 0
    _idle_input = InputState.new()
    _idle_delta_idx = -1
    _idle_event_idx = -1
    _physics_time = 0
    _physics_input = InputState.new()
    _physics_delta_idx = -1
    
    _idle_last_snapshot_time = 0
    _idle_delta = Delta.new()
    _physics_last_snapshot_time = 0
    _physics_delta = Delta.new()

func _input(event: InputEvent) -> void:
    if _mode != Mode.RECORDING:
        return

    if !_is_compatible_input_event(event):
        return

    event = event.duplicate(true)
    event.set_meta(_replay_event_meta_key, true)
    
    if len(recording.idle_input_events) == 0:
        var input_event = TimedInputEvents.new(_idle_time, [event])
        recording.idle_input_events.append(input_event)
        return
    
    var last_input_event := recording.idle_input_events[len(recording.idle_input_events) - 1]
    if last_input_event.time == _idle_time:
        last_input_event.events.append(event)
    else:
        var input_event = TimedInputEvents.new(_idle_time, [event])
        recording.idle_input_events.append(input_event)

func _process(delta: float) -> void:
    if _mode == Mode.OFF:
        return
    
    if _mode == Mode.RECORDING:
        # we do this on the beginning of this frame so we can accumulate calls to capture from the
        # last frame
        if !_idle_delta.changes.is_empty():
            _idle_delta.time = _idle_time
            recording.idle_deltas.append(_idle_delta)

            _idle_delta = Delta.new()

        _idle_time += delta
        _update_tick_input(_idle_delta, _idle_input)

        if (_idle_last_snapshot_time - _idle_time) >= recording.idle_snapshot_delay:
            recording.idle_input_snapshots.append(_idle_input.duplicate())
            _idle_last_snapshot_time = _idle_time

        return

    if _mode == Mode.REPLAYING:
        _idle_time += delta
        if len(recording.idle_deltas) == 0:
            # TODO: this shouldnt ever be true right?
            return
        
        if _idle_delta_idx < len(recording.idle_deltas) - 1:
            var next_delta := recording.idle_deltas[_idle_delta_idx + 1]
            if _idle_time > next_delta.time or is_equal_approx(_idle_time, next_delta.time):
                _idle_delta_idx += 1
                _apply_current_delta(next_delta, _idle_input)

        if _idle_event_idx < len(recording.idle_input_events) - 1:
            var next_timed_event := recording.idle_input_events[_idle_event_idx + 1]
            if _idle_time > next_timed_event.time or is_equal_approx(_idle_time, next_timed_event.time):
                _idle_event_idx += 1
                for event in next_timed_event.events:
                    Input.parse_input_event(event)

func _physics_process(delta: float) -> void:
    if _mode == Mode.OFF:
        return
    
    if _mode == Mode.RECORDING:
        # we do this on the beginning of this frame so we can accumulate calls to capture from the
        # last frame
        if !_physics_delta.changes.is_empty():
            _physics_delta.time = _physics_time
            recording.physics_deltas.append(_physics_delta)
            _physics_delta = Delta.new()

        _physics_time += delta
        _update_tick_input(_physics_delta, _physics_input)

        if (_physics_last_snapshot_time - _physics_time) >= recording.physics_snapshot_delay:
            recording.physics_input_snapshots.append(_physics_input.duplicate())
            _physics_last_snapshot_time = _physics_time
        
        return

    if _mode == Mode.REPLAYING:
        _physics_time += delta
        if len(recording.physics_deltas) == 0:
            # TODO: this shouldnt ever be true right?
            return
        
        if _physics_delta_idx < len(recording.physics_deltas) - 1:
            var next_delta := recording.physics_deltas[_physics_delta_idx + 1]
            if _physics_time > next_delta.time or is_equal_approx(_physics_time, next_delta.time):
                _physics_delta_idx += 1
                _apply_current_delta(next_delta, _physics_input)

static func _apply_delta_action(
    delta: Delta,
    actions: Dictionary[StringName, ActionState],
    key: _DeltaKey,
    setter: Callable
) -> void:
    if delta.changes.has(key):
        # Array[ActionValuePair]
        for item in delta.changes[key]:
            var pair: ActionChange = item
            var action_state: ActionState = actions.get(pair.name)
            if action_state == null:
                action_state = ActionState.new()
                actions[pair.name] = action_state
            
            setter.call(action_state, pair.value)

static func _apply_current_delta(delta: Delta, input: InputState) -> void:
    _apply_delta_action(
        delta,
        input.actions,
        _DeltaKey.Actions_JustPressed,
        func(state: ActionState, value: bool) -> void: state.just_pressed = value
    )

    _apply_delta_action(
        delta,
        input.actions,
        _DeltaKey.Actions_JustReleased,
        func(state: ActionState, value: bool) -> void: state.just_released = value
    )
    
    _apply_delta_action(
        delta,
        input.actions,
        _DeltaKey.Actions_Pressed,
        func(state: ActionState, value: bool) -> void: state.pressed = value
    )
    
    _apply_delta_action(
        delta,
        input.actions,
        _DeltaKey.Actions_RawStrength,
        func(state: ActionState, value: bool) -> void: state.raw_strength = value
    )
    
    _apply_delta_action(
        delta,
        input.actions,
        _DeltaKey.Actions_Strength,
        func(state: ActionState, value: bool) -> void: state.strength = value
    )
    _apply_delta_action(
        delta,
        input.actions_exact,
        _DeltaKey.ActionsExact_JustPressed,
        func(state: ActionState, value: bool) -> void: state.just_pressed = value
    )

    _apply_delta_action(
        delta,
        input.actions_exact,
        _DeltaKey.ActionsExact_JustReleased,
        func(state: ActionState, value: bool) -> void: state.just_released = value
    )
    
    _apply_delta_action(
        delta,
        input.actions_exact,
        _DeltaKey.ActionsExact_Pressed,
        func(state: ActionState, value: bool) -> void: state.pressed = value
    )
    
    _apply_delta_action(
        delta,
        input.actions_exact,
        _DeltaKey.ActionsExact_RawStrength,
        func(state: ActionState, value: bool) -> void: state.raw_strength = value
    )
    
    _apply_delta_action(
        delta,
        input.actions_exact,
        _DeltaKey.ActionsExact_Strength,
        func(state: ActionState, value: bool) -> void: state.strength = value
    )
    
    if delta.changes.has(_DeltaKey.MouseMode):
        input.mouse_mode = delta.changes[_DeltaKey.MouseMode]
    
    if delta.changes.has(_DeltaKey.LastMouseScreenVelocity):
        input.last_mouse_screen_velocity = delta.changes[_DeltaKey.LastMouseScreenVelocity]
    
    if delta.changes.has(_DeltaKey.LastMouseVelocity):
        input.last_mouse_velocity = delta.changes[_DeltaKey.LastMouseVelocity]
    
    if delta.changes.has(_DeltaKey.MouseButtonMask):
        input.mouse_button_mask = delta.changes[_DeltaKey.MouseButtonMask]
    
    if delta.changes.has(_DeltaKey.Captures):
        # Dictionary[StringName, Variant]
        var captures: Dictionary = delta.changes[_DeltaKey.Captures]
        for capture in captures:
            input.captures[capture] = captures[capture]

static func _update_tick_input(delta: Delta, input_state: InputState) -> void:
    var mouse_mode := Input.mouse_mode
    if input_state.mouse_mode != mouse_mode:
        input_state.mouse_mode = mouse_mode
        delta.changes[_DeltaKey.MouseMode] = mouse_mode
    
    var last_mouse_velocity := Input.get_last_mouse_velocity()
    if input_state.last_mouse_velocity != last_mouse_velocity:
        input_state.last_mouse_velocity = last_mouse_velocity
        delta.changes[_DeltaKey.LastMouseVelocity] = last_mouse_velocity
    
    var last_mouse_screen_velocity := Input.get_last_mouse_screen_velocity()
    if input_state.last_mouse_screen_velocity != last_mouse_screen_velocity:
        input_state.last_mouse_screen_velocity = last_mouse_screen_velocity
        delta.changes[_DeltaKey.LastMouseScreenVelocity] = last_mouse_screen_velocity
    
    var mouse_button_mask := Input.get_mouse_button_mask()
    if input_state.mouse_button_mask != mouse_button_mask:
        input_state.mouse_button_mask = mouse_button_mask
        delta.changes[_DeltaKey.MouseButtonMask] = mouse_button_mask

    for action in InputMap.get_actions():
        if action.begins_with("ui_"):
            continue

        _record_action_property(
            input_state,
            delta, _DeltaKey.Actions_RawStrength, _DeltaKey.ActionsExact_RawStrength,
            Input.get_action_raw_strength, action,
            func(state: ActionState) -> float: return state.raw_strength,
            func(state: ActionState, value: float) -> void: state.raw_strength = value
        )
        
        _record_action_property(
            input_state,
            delta, _DeltaKey.Actions_Strength, _DeltaKey.ActionsExact_Strength,
            Input.get_action_strength, action,
            func(state: ActionState) -> float: return state.strength,
            func(state: ActionState, value: float) -> void: state.strength = value
        )
        
        _record_action_property(
            input_state,
            delta, _DeltaKey.Actions_JustPressed, _DeltaKey.ActionsExact_JustPressed,
            Input.is_action_just_pressed, action,
            func(state: ActionState) -> bool: return state.just_pressed,
            func(state: ActionState, value: bool) -> void: state.just_pressed = value
        )
        
        _record_action_property(
            input_state,
            delta, _DeltaKey.Actions_JustReleased, _DeltaKey.ActionsExact_JustReleased,
            Input.is_action_just_released, action,
            func(state: ActionState) -> bool: return state.just_released,
            func(state: ActionState, value: bool) -> void: state.just_released = value
        )
        
        _record_action_property(
            input_state,
            delta, _DeltaKey.Actions_Pressed, _DeltaKey.ActionsExact_Pressed,
            Input.is_action_pressed, action,
            func(state: ActionState) -> bool: return state.pressed,
            func(state: ActionState, value: bool) -> void: state.pressed = value
        )

static func _record_action_property_inner(
    value,
    actions: Dictionary[StringName, ActionState],
    input_delta: Delta,
    delta_key: _DeltaKey,
    action: StringName,
    getter: Callable,
    setter: Callable,
) -> void:
    var last_state = actions.get(action)
    if last_state == null:
        # if its not already in the input state, that implies this is a brand new
        # action, and a new delta should always be added
        last_state = ActionState.new()
        actions[action] = last_state
        setter.call(last_state, value)
        input_delta.changes.get_or_add(delta_key, []).append(ActionChange.new(action, value))
        return
    
    if getter.call(last_state) != value:
        # otherwise, a different value between the previous value and the new value
        # means we need to add a new delta
        setter.call(last_state, value)
        input_delta.changes.get_or_add(delta_key, []).append(ActionChange.new(action, value))
        return

static func _record_action_property(
    input_state: InputState,
    input_delta: Delta,
    delta_key: _DeltaKey,
    delta_key_exact: _DeltaKey,
    input_func: Callable,
    action: StringName,
    getter: Callable,
    setter: Callable,
) -> void:
    var value = input_func.call(action, false)
    var value_exact = input_func.call(action, true)
    
    _record_action_property_inner(value, input_state.actions, input_delta, delta_key, action, getter, setter)
    _record_action_property_inner(value_exact, input_state.actions_exact, input_delta, delta_key_exact, action, getter, setter)

func ignore_event(event: InputEvent):
    event.set_meta(_replay_ignore_meta_key, true)

func is_replay_event(event: InputEvent) -> bool:
    return event.has_meta(_replay_event_meta_key)

## returns true if the event isn't sourced from the replay, or if its been tagged to be ignored via
## [method ignore_event]
func filtered_event(event: InputEvent) -> bool:
    return _mode == Mode.REPLAYING and (!event.has_meta(_replay_event_meta_key) or event.has_meta(_replay_ignore_meta_key))

func _get_capture_playback(key: StringName) -> Variant:
    var input_state := _idle_input
    if Engine.is_in_physics_frame():
        input_state = _physics_input

    var replay_value = input_state.captures.get(key)
    if replay_value == null:
        push_error("Capture key doesn't exist in replay: '%s'" % key)

    return replay_value

func _record_capture(key: StringName, value: Variant) -> void:
    var input_state := _idle_input
    var input_delta := _idle_delta
    if Engine.is_in_physics_frame():
        input_state = _physics_input
        input_delta = _physics_delta
    
    # we use has instead of a single call to Dictionary.get because captures can be nullable.
    # its impossible to distinguish a null entry vs no entry with Dictionary.get
    if !input_state.captures.has(key) or input_state.captures.get(key) != value:
        # if its not already in the input state, then its a brand new capture, and a new delta 
        # should always be added
        input_state.captures[key] = value
        input_delta.changes.get_or_add(_DeltaKey.Captures, {}).set(key, value)

func capture(key: StringName, value: Variant) -> Variant:
    match typeof(value):
        TYPE_OBJECT or TYPE_CALLABLE:
            push_error("attempted to capture an Object or Callable, which is not allowed.")
            return value

    if _mode == Mode.REPLAYING:
        return _get_capture_playback(key)
    
    if _mode == Mode.RECORDING:
        _record_capture(key, value)
    
    return value

var mouse_mode: Input.MouseMode:
    get:
        if _mode == Mode.REPLAYING:
            if Engine.is_in_physics_frame():
                return _physics_input.mouse_mode
            return _idle_input.mouse_mode
        return Input.mouse_mode
    set(value):
        if _mode == Mode.REPLAYING:
            return

        Input.mouse_mode = value

func _handle_action(action: StringName, exact_match: bool, input_func: Callable, getter: Callable) -> Variant:
    if _mode == Mode.REPLAYING:
        var input_state: InputState = _idle_input
        if Engine.is_in_physics_frame():
            input_state = _physics_input
        
        var actions: Dictionary[StringName, ActionState] = input_state.actions
        if exact_match:
            actions = input_state.actions_exact
        
        var action_state: ActionState = actions.get(action)
        if action_state == null:
            push_error("Action doesn't exist in replay: '%s'" % action)
            return null
        
        return getter.call(action_state)
    
    return input_func.call(action, exact_match)

func get_action_raw_strength(action: StringName, exact_match: bool = false) -> float:
    return _handle_action(
        action,
        exact_match,
        Input.get_action_raw_strength,
        func(state: ActionState) -> float: return state.raw_strength
    )

func get_action_strength(action: StringName, exact_match: bool = false) -> float:
    return _handle_action(
        action,
        exact_match,
        Input.get_action_strength,
        func(state: ActionState) -> float: return state.strength
    )

func is_action_just_pressed(action: StringName, exact_match: bool = false) -> bool:
    return _handle_action(
        action,
        exact_match,
        Input.is_action_just_pressed,
        func(state: ActionState) -> bool: return state.just_pressed
    )

func is_action_just_released(action: StringName, exact_match: bool = false) -> bool:
    return _handle_action(
        action,
        exact_match,
        Input.is_action_just_released,
        func(state: ActionState) -> bool: return state.just_released
    )

func is_action_pressed(action: StringName, exact_match: bool = false) -> bool:
    return _handle_action(
        action,
        exact_match,
        Input.is_action_pressed,
        func(state: ActionState) -> bool: return state.pressed
    )

func get_last_mouse_screen_velocity() -> Vector2:
    if _mode == Mode.REPLAYING:
        if Engine.is_in_physics_frame():
            return _physics_input.last_mouse_screen_velocity
        return _idle_input.last_mouse_screen_velocity
    return Input.get_last_mouse_screen_velocity()

func get_last_mouse_velocity() -> Vector2:
    if _mode == Mode.REPLAYING:
        if Engine.is_in_physics_frame():
            return _physics_input.last_mouse_velocity
        return _idle_input.last_mouse_velocity
    return Input.get_last_mouse_velocity()

func get_mouse_button_mask() -> int:
    if _mode == Mode.REPLAYING:
        if Engine.is_in_physics_frame():
            return _physics_input.mouse_button_mask
        return _idle_input.mouse_button_mask
    return Input.get_mouse_button_mask()

func is_mouse_button_pressed(button: int) -> bool:
    var flag := (1 << (button - 1))
    return (get_mouse_button_mask() & flag) == flag

func get_axis(negative_action: StringName, positive_action: StringName) -> float:
    return get_action_strength(positive_action) - get_action_strength(negative_action)

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
