extends Node

func _input(event: InputEvent) -> void:
    if event is InputEventKey and event.is_pressed():

        if event.keycode == KEY_P:
            await get_tree().physics_frame
            SReplay.record()
            return

        if event.keycode == KEY_O:
            await get_tree().physics_frame
            SReplay.stop()
            return
        
        if event.keycode == KEY_I:
            assert(get_tree().reload_current_scene() == OK)
            await get_tree().physics_frame
            
            SReplay.play()
            
            await get_tree().physics_frame
            Engine.time_scale = 0.5

            return
