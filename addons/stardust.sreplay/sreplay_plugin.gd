@tool
extends EditorPlugin

func _enter_tree() -> void:    
    add_autoload_singleton("SReplay", "res://addons/stardust.sreplay/sreplay.gd")
    print("SReplay plugin activated.")

func _exit_tree() -> void:
    remove_autoload_singleton("SReplay")
