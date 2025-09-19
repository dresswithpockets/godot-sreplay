class_name Portal extends Node

@export var scene: PackedScene

var _portaling: bool = false

func _player_entered(_node: Node3D) -> void:
    if _portaling:
        return

    _portaling = true
    call_deferred("activate")

func activate() -> void:
    get_tree().change_scene_to_packed(scene)
