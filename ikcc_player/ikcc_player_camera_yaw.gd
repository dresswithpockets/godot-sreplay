extends Node3D

@onready var camera: Camera3D = $Camera

func _input(event: InputEvent) -> void:
    if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        if event is InputEventKey and event.keycode == KEY_ESCAPE:
            Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
        
        if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
            move_camera(event.relative)

    else:
        if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed():
            Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func move_camera(relative_move: Vector2) -> void:
    var horizontal: float = relative_move.x * Settings.yaw_speed * Settings.mouse_speed
    var vertical: float = relative_move.y * Settings.pitch_speed * Settings.mouse_speed
    var yaw_rotation := deg_to_rad(-horizontal)
    var pitch_rotation := deg_to_rad(-vertical)
    rotate_y(yaw_rotation)
    camera.rotate_x(pitch_rotation)

func _on_player_moved(delta_position: Vector3) -> void:
    camera.position.y -= delta_position.y

func _process(delta: float) -> void:
    camera.position.y = Math.exp_decay_f(camera.position.y, 0, 20, delta)
