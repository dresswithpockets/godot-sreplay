class_name Portal extends Node

@export var scene: PackedScene

var _portaling: bool = false

func _ready() -> void:
    $Area.body_entered.connect(_player_entered)

func _player_entered(node: Node3D) -> void:
    if _portaling:
        return

    _portaling = true
    call_deferred("activate")

func activate() -> void:
    get_tree().change_scene_to_packed(scene)
