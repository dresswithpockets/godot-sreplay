# SReplay

SReplay is a replay (aka demo) system for Godot.

Features:

- Records inputs captured by `Input` functions
- Records `InputEvent`'s captured by `_unhandled_input`
- Records custom user data
- Records periodic cumulative frame states for later recall
- Deterministic playback of inputs, events, and user data
- Playback speed control
- Seek forward and backwards in playback instantly
- Recordings can be converted to dictionary for easy serialization

