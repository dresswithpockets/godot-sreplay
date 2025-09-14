extends Node

var _last_mouse_mode: Input.MouseMode
var _console_open: bool = false

func _input(event: InputEvent) -> void:
    if _console_open:
        return

    if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        if event is InputEventKey and event.keycode == KEY_ESCAPE:
            Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    else:
        if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed():
            Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _ready() -> void:
    _last_mouse_mode = Input.mouse_mode
    Console.console_opened.connect(_console_opened)
    Console.console_closed.connect(_console_closed)

func _console_opened() -> void:
    _last_mouse_mode = Input.mouse_mode
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    _console_open = true

func _console_closed() -> void:
    Input.mouse_mode = _last_mouse_mode
    _console_open = false
