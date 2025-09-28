extends Object

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

static func get_serializer_by_object(object: Object) -> void:
    if is_instance_of(object, InputEventMouseButton):
        pass
    pass

static func _InputEventMouseButton_serializer(event: InputEventMouseButton) -> void:
    pass
