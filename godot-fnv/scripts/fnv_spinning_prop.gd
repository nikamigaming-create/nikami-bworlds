extends Node3D

@export var radians_per_second := 1.15


func _process(delta: float) -> void:
	rotate_object_local(Vector3.RIGHT, radians_per_second * delta)
