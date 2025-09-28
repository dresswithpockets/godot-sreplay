extends Node
## Record input and node states into a replay, for future playback.
##
## Wraps calls to [Input] to capture input and provide a drop-in replacement for replay playback.
## When [method record] is called, SReplay will begin capturing input into a [member Recording],
## which can be serialized, deserialized, and played back later. When playing back a
## [member Recording] via [method play], SReplay will playback the recording's polled inputs
## and [InputEvent]'s. Calls to poll functions like [method get_vector] will return the recorded
## input state during playback, and will otherwise behave like normal calls to the [Input] API.
## [InputEvent]'s will also be played back across all nodes that have the method 
## [code]_sreplay_input(event: InputEvent)[/code].
## [br][br][br]
##
## [b]Input Polling:[/b][br]
## SReplay implements a similar API as [Input], except it only implements the
## mouse-related and action APIs. For example, if you are currently calling [Input] for movement
## like this:
##
## [codeblock language=gdscript]
## func _physics_process(delta: float) -> void:
##     var input_dir := Vector2.ZERO
##     if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
##         input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
## [/codeblock]
##
## Then you can use SReplay as a drop-in replacement by changing some of the references to [Input]
## with references to [SReplay]:
##
## [codeblock language=gdscript]
## func _physics_process(delta: float) -> void:
##     var input_dir := Vector2.ZERO
##     if SReplay.mouse_mode == Input.MOUSE_MODE_CAPTURED:
##         input_dir = SReplay.get_vector("move_left", "move_right", "move_forward", "move_back")
## [/codeblock]
## [br]
##
## [b]Input Events:[/b][br]
## Normally, if you want to capture [InputEvent] on your node, you have to 
## override [method Node._input], like so:
##
## [codeblock language=gdscript]
## func _input(event: InputEvent) -> void:
##     if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
##         move_camera(event.screen_relative)
## [/codeblock]
##
## However, in order to support playback of recorded [InputEvent]s, SReplay propogates a call
## to [code]_sreplay_input[/code] across the entire node tree, so the correct usage in your nodes 
## should change to this:
##
## [codeblock language=gdscript]
## func _sreplay_input(event: InputEvent) -> void:
##     if event is InputEventMouseMotion and SReplay.mouse_mode == Input.MOUSE_MODE_CAPTURED:
##         move_camera(event.screen_relative)
## [/codeblock]
##
## [b]Important:[/b] [code]_sreplay_input[/code] does not respect 
## [code]set_process_input(false)[/code]. If you want to disable input processing on the node, then
## you should gate it manually in [code]_sreplay_input[/code] by e.g.
## [code]if is_processing_input(): return[/code]
##

signal mode_changed(old: Mode, new: Mode)
signal shift_started(user_data: Variant)
signal seek_finished
signal playback_rate_changed(old: Rate, new: Rate)

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

enum Rate {
    PAUSED = 0,
    QUARTER = 1,
    HALF = 2,
    FULL = 4,
    DOUBLE = 8,
}
var playback_rate: Rate = Rate.FULL:
    get:
        return playback_rate
    set(r):
        if r == playback_rate:
            return

        var old_rate := playback_rate
        playback_rate = r
        playback_rate_changed.emit(old_rate, r)

var current_tick: int:
    get:
        return _physics_tick

static func is_compatible_input_event(event: InputEvent) -> bool:
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

const compatible_input_event_class_names: Array[String] = [
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

## Begin recording a new replay on the next physics tick. [br][br]
##
## [b]IMPORTANT:[/b] Do not call this function on the idle frame! Consider it undefined behaviour.
## [br][br]
##
## SReplay will assign a new [SReplay.Recording] to [member recording], which will contain the 
## replay.[br][br]
##
## [param user_data] must not be an object, signal, or callable. If provided, [param user_data] will
## be stored in the new [SReplay.Recording]. See [SReplay.Recording] for more information. [br][br]
##
## By default, this will record an arbitrarily-long replay until stop is called. However, if 
## [param length] is greater than 0, then the recording will be created in buffered mode. After 
## [param length]-snapshots have passed in the recording, then the beginning of the replay will be
## trimmed to keep the recording at [param length]-snapshots in length. [br][br]
##
## Calls to [Input] differ in behaviour between physics and idle ticks. Replays occasionally take 
## full snapshots of the entire input state on idle ticks and on physics ticks, in order to enable 
## bidirectional navigation of the replay during playback. You can control how frequently snapshots
## are captured by varying [param snapshot_period], which specify the amount of time between
## each snapshot.
func record(
    func_user_data: Variant = null,
    length: int = 0,
    snapshot_period: float = 0.5,
) -> void:
    if func_user_data:
        if typeof(func_user_data) != TYPE_CALLABLE:
            push_error("get_user_data must be a Callable that returns a valid user_data object")
            return

    # TODO: record during playback to "edit" the recording?
    if _mode != Mode.OFF:
        push_error("attempted to record while recording or replaying a replay")
        return
    
    # in order to ensure the start of our recording is deterministic, mode changes must always occur
    # on the physics tick
    if !Engine.is_in_physics_frame():
        await get_tree().physics_frame
        record(func_user_data, length, snapshot_period)
        return

    var user_data: Variant = null
    if func_user_data:
        user_data = (func_user_data as Callable).call()
        if typeof(user_data) in [TYPE_OBJECT, TYPE_SIGNAL, TYPE_CALLABLE]:
            push_error("func_user_data.call() returned an Object, Signal, or Callable, which are not supported")
            return

    _mode = Mode.RECORDING
    _reset()
    
    # TODO: support specifying length in Recording to trim the head of the recording as time exceeds the length

    # we always want the zeroth tick to have a snapshot
    _physics_last_snapshot_time = -snapshot_period
    _func_user_data = func_user_data
    recording = Recording.new(snapshot_period, user_data)
    mode_changed.emit(Mode.OFF, _mode)

## Stops recording a replay on the next physics tick. [br][br]
##
## Access the replay from [member recording].
func stop() -> void:
    if _mode == Mode.OFF:
        return
    
    # in order to ensure the start of our recording is deterministic, mode changes must always occur
    # on the physics tick
    if !Engine.is_in_physics_frame():
        await get_tree().physics_frame
        stop()
        return

    if _mode == Mode.RECORDING:
        recording.max_tick = _physics_tick

    _reset()

    var old_mode := _mode
    _mode = Mode.OFF
    mode_changed.emit(old_mode, _mode)

## Begin replaying the [member recording] property on the next physics tick. Errors if a replay is 
## being recorded or played back.
func play(func_apply_user_data: Variant = null) -> void:
    if _mode != Mode.OFF:
        push_error("attempted to play while already recording or replaying a replay")
        return

    if recording == null:
        push_error("attempting to play null recording")
        return
    
    if recording.is_empty():
        push_error("attempting to play empty recording")
        return
    
    
    # in order to ensure the start of our recording is deterministic, mode changes must always occur
    # on the physics tick
    if !Engine.is_in_physics_frame():
        await get_tree().physics_frame
        play()
        return
    
    _reset()

    _func_apply_user_data = func_apply_user_data
    _mode = Mode.REPLAYING
    mode_changed.emit(Mode.OFF, _mode)

func restart() -> void:
    if _mode != Mode.REPLAYING:
        push_error("attempted to restart playback, but SReplay isn't playing back a replay")
        return

    if recording == null:
        push_error("attempting to restart a null recording")
        return
    
    if recording.is_empty():
        push_error("attempting to restart an empty recording")
        return
    
    # in order to ensure the start of our recording is deterministic, playback must always begin on
    # the physics tick
    if !Engine.is_in_physics_frame():
        await get_tree().physics_frame
        restart()
        return
    
    _reset()

func seek(tick: int, play_until: bool = false) -> void:
    if _mode != Mode.REPLAYING:
        push_error("attempted to seek playback, but SReplay isn't playing back a replay")
        return
    
    if tick == 0:
        restart()
        seek_finished.emit()
        return
    
    if _physics_tick == tick:
        seek_finished.emit()
        return
    
    # saeeking requires replacing our current state with a snapshot, followed by playback until we
    # get to the correct tick. So, first we need to find the state that correlates to our tick
    var snapshot: Snapshot
    var new_idx := 0
    for idx in len(recording.snapshots):
        var next := recording.snapshots[idx]
        if tick < next.physics_tick:
            break

        snapshot = next
        new_idx = idx

    if new_idx != _snapshot_idx or tick < _physics_tick:
        _snapshot_idx = new_idx
        _physics_tick = snapshot.physics_tick
        _sreplay_tick = _physics_tick * Rate.FULL
        _apply_current_snapshot(snapshot)

        var root: Node = get_tree().get_root()
        for event in recording.idle_input_events[_idle_event_idx].events:
            root.propagate_call("_sreplay_input", [event])

    if play_until and tick != _physics_tick:
        assert(tick > _physics_tick)
        
        var tick_diff := tick - _physics_tick
        var old_rate := playback_rate

        playback_rate = tick_diff * Rate.FULL
        await get_tree().physics_frame
        await get_tree().physics_frame
        playback_rate = old_rate
    
    seek_finished.emit()

func _apply_current_snapshot(snapshot: Snapshot) -> void:
    _physics_delta_idx = snapshot.physics_delta_idx
    _physics_input = snapshot.physics_input_state.duplicate()
    # TODO: do we need to call _apply_current_delta? The snapshot's input state should include the 
    #       delta from this snapshot
    _apply_current_delta(recording.physics_deltas[_physics_delta_idx], _physics_input)

    _idle_time = snapshot.idle_time
    _idle_delta_idx = snapshot.idle_delta_idx
    _idle_event_idx = snapshot.idle_event_idx
    _idle_input = snapshot.idle_input_state.duplicate()
    # TODO: do we need to call _apply_current_delta? The snapshot's input state should include the 
    #       delta from this snapshot
    _apply_current_delta(recording.idle_deltas[_idle_delta_idx], _idle_input)
    
    _func_apply_user_data.call(snapshot.user_data)

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
        result[key] = callable.call(from[key])
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
    var tick: int
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
            "tick": delta.tick,
            "changes": changes,
        }
    
    static func from_dict(from: Dictionary) -> Delta:
        var delta := Delta.new()
        delta.time = from["time"]
        delta.tick = from["tick"]
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
        if event_class not in compatible_input_event_class_names:
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
        new.raw_strength = raw_strength
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
        new.raw_strength = from["raw_strength"]
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
            "last_mouse_screen_velocity": var_to_str(from.last_mouse_screen_velocity),
            "last_mouse_velocity": var_to_str(from.last_mouse_velocity),
            "mouse_button_mask": from.mouse_button_mask,
            "captures": var_to_str(from.captures),
        }
    
    static func from_dict(from: Dictionary) -> InputState:
        var actions: Dictionary = from["actions"]
        var actions_exact: Dictionary = from["actions_exact"]
        var mouse_mode: Input.MouseMode = from["mouse_mode"]
        var last_mouse_screen_velocity: Vector2 = str_to_var(from["last_mouse_screen_velocity"])
        var last_mouse_velocity: Vector2 = str_to_var(from["last_mouse_velocity"])
        var mouse_button_mask: int = from["mouse_button_mask"]
        var captures: Dictionary = str_to_var(from["captures"])
        
        var mapped_actions: Dictionary[StringName, ActionState] = {}
        mapped_actions.assign(SReplay._map_dict_values(actions, ActionState.from_dict))
        var mapped_actions_exact: Dictionary[StringName, ActionState] = {}
        mapped_actions_exact.assign(SReplay._map_dict_values(actions_exact, ActionState.from_dict))
        var mapped_captures: Dictionary[StringName, Variant] = {}
        mapped_captures.assign(captures)
        return InputState.new(
            mapped_actions,
            mapped_actions_exact,
            mouse_mode,
            last_mouse_screen_velocity,
            last_mouse_velocity,
            mouse_button_mask,
            mapped_captures,
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

class TickTime extends RefCounted:
    ## should always be the physics tick
    var tick: int
    var time: float
    var delta_idx: int
    var event_idx: int
    var snapshot_idx: int
    
    func _init(
        p_tick: int,
        p_time: float,
        p_delta_idx: int,
        p_event_idx: int,
        p_snapshot_idx: int,
    ) -> void:
        tick = p_tick
        time = p_time
        delta_idx = p_delta_idx
        event_idx = p_event_idx
        snapshot_idx = p_snapshot_idx
    
    static func to_dict(from: TickTime) -> Dictionary:
        return {
            "tick": from.tick,
            "time": from.time,
            "delta_idx": from.delta_idx,
            "event_idx": from.event_idx,
            "snapshot_idx": from.snapshot_idx,
        }
    
    static func from_dict(from: Dictionary) -> TickTime:
        var tick: int = from["tick"]
        var time: float = from["time"]
        var delta_idx: float = from["delta_idx"]
        var event_idx: float = from["event_idx"]
        var snapshot_idx: float = from["snapshot_idx"]
        
        return TickTime.new(tick, time, delta_idx, event_idx, snapshot_idx)

class Snapshot extends RefCounted:
    ## should always be the physics tick
    var physics_tick: int
    var physics_delta_idx: int
    var idle_time: float
    var idle_delta_idx: int
    var idle_event_idx: int

    var idle_input_state: InputState
    var physics_input_state: InputState
    var user_data: Variant
    
    func _init(
        p_physics_tick: int,
        p_physics_delta_idx: int,
        p_idle_time: float,
        p_idle_delta_idx: int,
        p_idle_event_idx: int,
        p_idle_input_state: InputState,
        p_physics_input_state: InputState,
        p_user_data: Variant = null
    ) -> void:
        physics_tick = p_physics_tick
        physics_delta_idx = p_physics_delta_idx
        idle_time = p_idle_time
        idle_delta_idx = p_idle_delta_idx
        idle_event_idx = p_idle_event_idx
        
        idle_input_state = p_idle_input_state
        physics_input_state = p_physics_input_state
        user_data = p_user_data
    
    static func to_dict(from: Snapshot) -> Dictionary:
        return {
            "physics_tick": from.physics_tick,
            "physics_delta_idx": from.physics_delta_idx,
            "idle_time": from.idle_time,
            "idle_delta_idx": from.idle_delta_idx,
            "idle_event_idx": from.idle_event_idx,
            
            "idle_input_state": InputState.to_dict(from.idle_input_state),
            "physics_input_state": InputState.to_dict(from.physics_input_state),
            "user_data": from.user_data,
        }
    
    static func from_dict(from: Dictionary) -> Snapshot:
        var physics_tick: int = from["physics_tick"]
        var physics_delta_idx: int = from["physics_delta_idx"]
        var idle_time: float = from["idle_time"]
        var idle_delta_idx: int = from["idle_delta_idx"]
        var idle_event_idx: int = from["idle_event_idx"]
        
        var idle_input_state := InputState.from_dict(from["idle_input_state"])
        var physics_input_state := InputState.from_dict(from["physics_input_state"])
        var user_data: Variant = from.get("user_data")
        
        return Snapshot.new(
            physics_tick,
            physics_delta_idx,
            idle_time,
            idle_delta_idx,
            idle_event_idx,
            idle_input_state,
            physics_input_state,
            user_data,
        )

## A recording of all polled inputs, input events, and snapshots.
class Recording extends RefCounted:
    var snapshot_delay := 1.0
    var user_data: Variant
    var max_tick: int

    var idle_deltas: Array[Delta] = []
    var idle_input_events: Array[TimedInputEvents] = []
    var physics_deltas: Array[Delta] = []
    var snapshots: Array[Snapshot] = []
    # TODO: Node state snapshotting

    func _init(
        p_snapshot_delay: float,
        p_user_data: Variant
    ) -> void:
        snapshot_delay = p_snapshot_delay
        user_data = p_user_data
    
    func is_empty() -> bool:
        return idle_deltas.is_empty() and idle_input_events.is_empty() and physics_deltas.is_empty() and snapshots.is_empty()
    
    func to_dict() -> Dictionary:
        return {
            "snapshot_delay": snapshot_delay,
            "user_data": user_data,
            "max_tick": max_tick,

            "idle_deltas": idle_deltas.map(Delta.to_dict),
            "idle_input_events": idle_input_events.map(TimedInputEvents.to_dict),
            "physics_deltas": physics_deltas.map(Delta.to_dict),
            "snapshots": snapshots.map(Snapshot.to_dict)
        }
    
    static func from_dict(from: Dictionary) -> Recording:
        var snapshot_delay: float = from["snapshot_delay"]
        var user_data: Variant = from.get("user_data")
        var max_tick: int = from["max_tick"]
        
        var idle_deltas: Array = from["idle_deltas"]
        var idle_input_events: Array = from["idle_input_events"]
        var physics_deltas: Array = from["physics_deltas"]
        var snapshots: Array = from["snapshots"]
        
        var recording := Recording.new(snapshot_delay, user_data)
        recording.max_tick = max_tick
        recording.idle_deltas.assign(idle_deltas.map(Delta.from_dict))
        recording.idle_input_events.assign(idle_input_events.map(TimedInputEvents.from_dict))
        recording.physics_deltas.assign(physics_deltas.map(Delta.from_dict))
        recording.snapshots.assign(snapshots.map(Snapshot.from_dict))
        return recording

var recording: Recording

func _null_user_data() -> Variant:
    return null

func _apply_empty_user_data(_from: Dictionary) -> void:
    pass

# used in both recording and replaying mode
var _func_user_data: Callable = _null_user_data
var _func_apply_user_data: Callable = _apply_empty_user_data
var _idle_time: float
var _idle_input: InputState = InputState.new()
var _idle_delta_idx: int = -1
var _idle_event_idx: int = -1
var _unscaled_physics_time: float
var _sreplay_tick: int = 0
var _physics_tick: int = 0
var _physics_input: InputState = InputState.new()
var _physics_delta_idx: int = -1
var _snapshot_idx: int = -1

# only used in recording mode
var _idle_time_previous: float
var _idle_delta: Delta = Delta.new()
var _physics_last_snapshot_time: float
var _physics_delta: Delta = Delta.new()
var _retro_max_snapshots: int = 0

# only used in replaying mode
var _sreplay_tick_delta: int = 0

func _reset() -> void:
    _func_user_data = _null_user_data
    _func_apply_user_data = _apply_empty_user_data
    _idle_time = 0
    _idle_input = InputState.new()
    _idle_delta_idx = -1
    _idle_event_idx = -1
    _unscaled_physics_time = 0
    _sreplay_tick = 0
    _physics_tick = 0
    _physics_input = InputState.new()
    _physics_delta_idx = -1
    _snapshot_idx = -1
    _last_physics_usec = 0
    _min_idle_time = 0
    _max_idle_time = 0

    _idle_time_previous = 0
    _idle_delta = Delta.new()
    _physics_last_snapshot_time = 0
    _physics_delta = Delta.new()
    
    _sreplay_tick_delta = 0

func _record_event(event: InputEvent) -> void:
    if !is_compatible_input_event(event):
        return

    event = event.duplicate(true)
    
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

func _unhandled_input(event: InputEvent) -> void:
    if _mode == Mode.RECORDING:
        _record_event(event)

    # N.B. we pass the event along to _sreplay_input, but this ignores `set_process_input(false)`.
    #      I could track every node in the tree that has `_sreplay_input` overriden, but this
    #      but this is simpler, and in most cases where `_input` is overriden, input processing
    #      is not disabled. I'll leave it up to the user of this utility to handle disabling
    #      input on their nodes. e.g. just something like this:
    #
    #    func _sreplay_input(event: InputEvent) -> void:
    #        if !is_processing_input():
    #            return
    #        ...
    #

    if _mode != Mode.REPLAYING:
        _apply_events([event], get_tree().get_root())

var _last_physics_usec: int = 0
var _min_idle_time: float = 0
var _max_idle_time: float = 0

func _process(delta: float) -> void:
    if _mode == Mode.OFF:
        return
    
    if _mode == Mode.RECORDING:
        # we do this on the beginning of this frame so we can accumulate calls to capture from the
        # last frame
        if !_idle_delta.changes.is_empty():
            _idle_delta.time = _idle_time_previous
            recording.idle_deltas.append(_idle_delta)
            _idle_delta = Delta.new()

        _idle_time_previous = _idle_time
        _idle_time += delta
        _update_tick_input(_idle_delta, _idle_input)

    if _mode == Mode.REPLAYING:
        assert(len(recording.idle_deltas) > 0)

        # scaling our max idle time based on our playtime. if we're playing at quarter speed, then
        # idle shouldn't exceed a fourth of the usual frame time
        var seconds_per_ptick := 1.0 / float(Engine.physics_ticks_per_second)
        var sticks_per_ptick := _sreplay_tick_delta / float(Rate.FULL)
        var max_idle_time := _min_idle_time + sticks_per_ptick * seconds_per_ptick
        _idle_time = clampf(_idle_time, _min_idle_time, max_idle_time)

        for idx in range(_idle_delta_idx + 1, len(recording.idle_deltas)):
            var next := recording.idle_deltas[idx]
            if _idle_time > next.time or is_equal_approx(_idle_time, next.time):
                _idle_delta_idx = idx
                _apply_current_delta(next, _idle_input)
        
        var root: Node = get_tree().get_root()
        for idx in range(_idle_event_idx + 1, len(recording.idle_input_events)):
            var next := recording.idle_input_events[idx]
            if _idle_time > next.time or is_equal_approx(_idle_time, next.time):
                _idle_event_idx = idx
                _apply_events(next.events, root)

        # we still want to scale time based on the playback rate. Rate constants are a all relative
        # to the fullspeed constant Rate.FULL. So Rate.HALF = 4 would result in 50% speed, or a 0.5
        # multiplayer
        _idle_time += delta

func _physics_process(_delta: float) -> void:
    if _mode == Mode.OFF:
        return
    
    if _mode == Mode.RECORDING:
        # we do this on the beginning of this frame so we can accumulate calls to capture from the
        # last frame
        if !_physics_delta.changes.is_empty():
            _physics_delta.time = _idle_time
            _physics_delta.tick = _physics_tick - 1
            recording.physics_deltas.append(_physics_delta)
            _physics_delta = Delta.new()

        # during recording, we want to capture snapshots occasionally. Snapshots occur every 
        # `snapshot_delay` seconds, from the very first tick after recording. We wait for changes
        # to have accumulated from the previous frame before snapshotting.
        #
        # snapshots will be used during playback to perform a few operations:
        # - ensure time is synced for the duration of the playback
        # - scrubbing/shifting to a particular tick,
        if (_unscaled_physics_time - _physics_last_snapshot_time) >= recording.snapshot_delay:
            recording.snapshots.append(
                Snapshot.new(
                    _physics_tick,
                    len(recording.physics_deltas) - 1,
                    _idle_time_previous,
                    len(recording.idle_deltas) - 1,
                    len(recording.idle_input_events) - 1,
                    _idle_input.duplicate(),
                    _physics_input.duplicate(),
                    _func_user_data.call(),
                )
            )
            _physics_last_snapshot_time = _unscaled_physics_time
            
            if _retro_max_snapshots > 0 and len(recording.snapshots) > _retro_max_snapshots:
                # if we have 35 snapshots, and the max is 30, then we need to remove 5 snapshots
                # and the new head will be the 6th one.
                var snapshots_to_remove := len(recording.snapshots) - _retro_max_snapshots
                recording.snapshots = recording.snapshots.slice(snapshots_to_remove)
                
                # we trim deltas & events up to this snapshot
                var new_head := recording.snapshots[0]
                recording.idle_deltas = recording.idle_deltas.slice(new_head.idle_delta_idx)
                recording.idle_input_events = recording.idle_input_events.slice(new_head.idle_event_idx)
                recording.physics_deltas = recording.physics_deltas.slice(new_head.physics_delta_idx)
                _idle_time_previous -= new_head.idle_time
                _idle_time -= new_head.idle_time
                _physics_tick -= new_head.physics_tick
                
                for snapshot_idx in range(len(recording.snapshots) - 1, 0, -1):
                    var snapshot := recording.snapshots[snapshot_idx]
                    snapshot.idle_delta_idx -= new_head.idle_delta_idx
                    snapshot.idle_event_idx -= new_head.idle_event_idx
                    snapshot.idle_time -= new_head.idle_time
                    snapshot.physics_delta_idx -= new_head.physics_delta_idx
                    snapshot.physics_tick -= new_head.physics_tick
        
        _update_tick_input(_physics_delta, _physics_input)

        _unscaled_physics_time += (1.0 / Engine.physics_ticks_per_second)
        _physics_tick += 1
        return

    if _mode == Mode.REPLAYING:
        assert(len(recording.physics_deltas) > 0)

        # we use _physics_tick to determine what our _idle_time and _physics_time should be, based
        # on the snapshots taken. Then we interpolate _idle_time and _physics_time by adding delta
        # to them every _process and _physics_process
        var has_new_snapshot := false
        for idx in range(_snapshot_idx + 1, len(recording.snapshots)):
            if _physics_tick < recording.snapshots[idx].physics_tick:
                break

            _snapshot_idx = idx
            has_new_snapshot = true
        
        # IMPORTANT: whenever we apply a snapshot, it may cause _idle_time to skip ahead or behind
        # depending on how the game has been performing in replay. SReplay cannot guarantee that
        # every idle input state/event is replayed, or that each state/event is replayed only once.
        # We can only say that it will on average replay every idle-frame state/event about 1 time.
        if has_new_snapshot:
            _apply_current_snapshot(recording.snapshots[_snapshot_idx])
            pass

        for idx in range(_physics_delta_idx + 1, len(recording.physics_deltas)):
            var next_delta := recording.physics_deltas[idx]
            if _physics_tick < next_delta.tick:
                break

            _physics_delta_idx = idx
            _apply_current_delta(next_delta, _physics_input)

        _min_idle_time = _idle_time

        var previous_tick := _sreplay_tick
        _sreplay_tick += playback_rate
        #if playback_rate != Rate.PAUSED:
            #_sreplay_tick -= _sreplay_tick % playback_rate
        
        _sreplay_tick_delta = _sreplay_tick - previous_tick
        _physics_tick = _sreplay_tick / Rate.FULL

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

static func _apply_events(events: Array[InputEvent], root: Node) -> void:
    for event in events:
        root.propagate_call("_sreplay_input", [event])

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
        TYPE_OBJECT or TYPE_CALLABLE or TYPE_SIGNAL:
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
