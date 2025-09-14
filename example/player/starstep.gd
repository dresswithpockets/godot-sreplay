class_name StarstepBody3D extends CharacterBody3D

@export_group("Stairs")
@export var max_step_height: float = 0.6
@export var max_step_up_slide_iterations: int = 6
@export var step_horizontal_threshold: float = 2
@export var step_ignore_horizontal_treshold: bool = true

var delta_position: Vector3 = Vector3.ZERO

func star_move_and_slide() -> void:
    var old_origin := global_position
    var delta: float
    if Engine.is_in_physics_frame():
        delta = get_physics_process_delta_time()
    else:
        delta = get_process_delta_time()

    var was_on_floor := is_on_floor()

    _step_up(delta)
    _move_and_slide()
    _step_down(was_on_floor)
    
    delta_position = global_position - old_origin

func _move_and_slide() -> void:
    # this player controller prioritizes horizontal movement, so we only move on the horizontal
    # plane for the first iteration
    var vertical_speed := velocity.y
    velocity.y = 0
    move_and_slide()

    # then we can perform the vertical iteration
    var horizontal_velocity := Vector3(velocity.x, 0, velocity.z)
    vertical_speed += velocity.y
    velocity = Vector3(0, vertical_speed, 0)
    move_and_slide()

    velocity.x += horizontal_velocity.x
    velocity.z += horizontal_velocity.z

func _iterate_sweep(
    sweep_transform: Transform3D,
    motion: Vector3,
    result: KinematicCollision3D
) -> Transform3D:
    for i in max_step_up_slide_iterations:
        var hit := test_move(sweep_transform, motion, result, safe_margin)
        sweep_transform = sweep_transform.translated(result.get_travel())
        if not hit:
            break

        var ceiling_normal := result.get_normal()
        motion = motion.slide(ceiling_normal)
    
    return sweep_transform

func _step_up(delta: float) -> void:
    var horizontal_velocity := Vector3(velocity.x, 0, velocity.z)
    if !is_on_floor() or horizontal_velocity == Vector3.ZERO:
        return
    
    var threshold_squared := step_horizontal_threshold * step_horizontal_threshold
    if !step_ignore_horizontal_treshold and horizontal_velocity.length_squared() < threshold_squared:
        return

    var sweep_transform := global_transform

    # don't run through if theres nothing for us to step up onto
    var result := KinematicCollision3D.new()
    if !test_move(sweep_transform, horizontal_velocity * delta, result, safe_margin):
        return

    var horizontal_remainder := result.get_remainder()

    # sweep up
    sweep_transform = sweep_transform.translated(result.get_travel())
    var pre_sweep_y := sweep_transform.origin.y
    sweep_transform = _iterate_sweep(sweep_transform, Vector3(0, max_step_height, 0), result)

    var height_travelled := sweep_transform.origin.y - pre_sweep_y
    if height_travelled <= 0:
        return

    # sweep forward using player's velocity
    sweep_transform = _iterate_sweep(sweep_transform, horizontal_remainder, result)

    # sweep back down, at most the amount we travelled from the sweep up
    if !test_move(sweep_transform, Vector3(0, -height_travelled, 0), result, safe_margin):
        # don't bother if we don't hit anything
        return

    var floor_angle = result.get_normal().angle_to(Vector3.UP)
    if absf(floor_angle) > floor_max_angle:
        return

    sweep_transform = sweep_transform.translated(result.get_travel())

    global_position.y = sweep_transform.origin.y

func _step_down(was_on_floor: bool) -> void:
    if !was_on_floor and !is_on_floor() and velocity.y < 0:
        return

    var result := KinematicCollision3D.new()

    if !test_move(global_transform, Vector3(0, -max_step_height, 0), result, safe_margin):
        return

    var new_transform := global_transform.translated(result.get_travel())

    global_transform = new_transform
    apply_floor_snap()
