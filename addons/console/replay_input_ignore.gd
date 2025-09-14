extends Control

func _input(event: InputEvent) -> void:
    if SReplay.is_replay_event(event):
        return
