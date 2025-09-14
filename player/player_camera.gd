class_name PlayerCamera extends Camera3D

const replay_player_camera_yaw = &"player_camera_yaw"
const replay_player_camera_pitch = &"player_camera_pitch"
const replay_player_camera_position = &"player_camera_position"

@export var mount: Node3D

var yaw: Basis = Basis.IDENTITY
var _pitch: Basis = Basis.IDENTITY

func _input(event: InputEvent) -> void:
    if SReplay.filtered_event(event):
        return

    if event is InputEventMouseMotion and SReplay.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        move_camera(event.screen_relative)

func move_camera(relative_move: Vector2) -> void:
    var horizontal: float = relative_move.x * Settings.yaw_speed * Settings.mouse_speed
    var vertical: float = relative_move.y * Settings.pitch_speed * Settings.mouse_speed
    var yaw_rotation := deg_to_rad(-horizontal)
    var pitch_rotation := deg_to_rad(-vertical)
    yaw = yaw.rotated(Vector3.UP, yaw_rotation)
    _pitch = _pitch.rotated(Vector3.RIGHT, pitch_rotation)
    global_basis = yaw * _pitch

func _ready() -> void:
    top_level = true
    physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
    yaw = Basis.from_euler(Vector3(0, global_rotation.y, 0))
    _pitch = Basis.from_euler(Vector3(global_rotation.x, 0, 0))

    if !is_instance_valid(mount):
        push_error("Can't interpolate camera without a valid mount!")

func _process(_delta: float) -> void:
    global_position = mount.get_global_transform_interpolated().origin

func _physics_process(_delta: float) -> void:
    yaw = SReplay.capture(replay_player_camera_yaw, yaw)
    _pitch = SReplay.capture(replay_player_camera_pitch, _pitch)
    global_basis = yaw * _pitch
    global_position = SReplay.capture(replay_player_camera_position, global_position)
