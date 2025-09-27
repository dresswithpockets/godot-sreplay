class_name Player extends StarstepBody3D

@export var camera: PlayerCamera

@export_group("Movement")
@export_subgroup("On Ground")
@export var ground_friction: float = 20.0
@export var ground_accel: float = 100.0
@export var ground_max_speed: float = 5.0

@export_subgroup("In Air")
@export var gravity_up_scale: float = 1.0
@export var gravity_down_scale: float = 1.0
@export var air_friction: float = 10.0
@export var air_accel: float = 50.0
@export var air_max_speed: float = 3.0
@export var max_vertical_speed: float = 15.0

signal moved(delta_position: Vector3)

var vertical_speed: float = 0
var horizontal_velocity: Vector3 = Vector3.ZERO

func _physics_process(delta: float) -> void:
    var wish_dir := get_wish_dir()
    update_velocity(delta, wish_dir)

    # N.B. this is a little game feel hack. It feels kind of weird for the player controller to step
    # up/down when the player isn't pressing any movement keys and speed is low. This prevents that
    # specific situation from happening.
    step_ignore_horizontal_treshold = wish_dir != Vector3.ZERO

    star_move_and_slide()
    horizontal_velocity = Vector3(velocity.x, 0, velocity.z)
    vertical_speed = velocity.y

    if delta_position != Vector3.ZERO:
        moved.emit(delta_position)

func get_wish_dir() -> Vector3:
    var input_dir := Vector2.ZERO
    if SReplay.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        input_dir = SReplay.get_vector("move_left", "move_right", "move_forward", "move_back")
    
    return camera.yaw * Vector3(input_dir.x, 0, input_dir.y)

func update_velocity(delta: float, wish_dir: Vector3) -> void:
    if is_on_floor():
        move_player_grounded(wish_dir, delta)
    else:
        move_player_air(wish_dir, delta)

    apply_gravity(delta)

    velocity = horizontal_velocity + Vector3.UP * vertical_speed

func move_player_grounded(wish_dir: Vector3, delta: float) -> void:
    if wish_dir == Vector3.ZERO:
        horizontal_velocity = Math.exp_decay_v3(horizontal_velocity, Vector3.ZERO, ground_friction, delta)
        if horizontal_velocity.is_zero_approx():
            horizontal_velocity = Vector3.ZERO
    else:
        horizontal_velocity += wish_dir * ground_accel * delta

    horizontal_velocity = horizontal_velocity.limit_length(ground_max_speed)

func move_player_air(wish_dir: Vector3, delta: float) -> void:
    if wish_dir == Vector3.ZERO:
        horizontal_velocity = Math.exp_decay_v3(horizontal_velocity, Vector3.ZERO, air_friction, delta)
        if horizontal_velocity.is_zero_approx():
            horizontal_velocity = Vector3.ZERO
    else:
        horizontal_velocity += wish_dir * air_accel * delta

    horizontal_velocity = horizontal_velocity.limit_length(air_max_speed)

func apply_gravity(delta: float) -> void:
    if vertical_speed > -max_vertical_speed:
        # jolt still returns 0 total_gravity :(
        # var gravity := PhysicsServer3D.body_get_direct_state(get_rid()).total_gravity
        var gravity := Vector3.DOWN * 10
        if vertical_speed > 0 or is_on_floor():
            gravity *= gravity_up_scale
        else:
            gravity *= gravity_down_scale

        vertical_speed += gravity.y * delta

        if vertical_speed < -max_vertical_speed:
            vertical_speed = -max_vertical_speed

func to_state_dict() -> Dictionary:
    return {
        "position": var_to_str(global_position),
        "camera": camera.to_state_dict(),
    }

func update_state_from_dict(state: Dictionary) -> void:
    @warning_ignore("unsafe_call_argument", "unsafe_cast")
    global_position = str_to_var(state["position"])
    reset_physics_interpolation()

    @warning_ignore("unsafe_call_argument", "unsafe_cast")
    camera.update_state_from_dict(state["camera"])
