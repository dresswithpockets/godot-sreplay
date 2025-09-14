extends Node3D

const VERTICAL_INTERPOLATION_STRENGTH: float = 20

func _on_player_moved(delta_position: Vector3) -> void:
    position.y -= delta_position.y

func _process(delta: float) -> void:
    position.y = Math.exp_decay_f(position.y, 0, VERTICAL_INTERPOLATION_STRENGTH, delta)
