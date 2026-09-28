"""Run inside Blender via scripts/character_blender.sh check; no game asset writes."""

import json
import math

import bpy


def expect_rejected(authoring, fragment):
    try:
        authoring.export_assets()
    except ValueError as error:
        assert fragment in str(error), str(error)
        return
    raise AssertionError(f"Expected export to reject {fragment}")


def compare_values(actual, expected):
    if isinstance(expected, dict):
        assert actual.keys() == expected.keys()
        for key in expected:
            compare_values(actual[key], expected[key])
    elif isinstance(expected, list):
        assert len(actual) == len(expected)
        for first, second in zip(actual, expected):
            compare_values(first, second)
    elif isinstance(expected, float):
        assert math.isclose(actual, expected, abs_tol=1e-7), (actual, expected)
    else:
        assert actual == expected


def run(authoring, output):
    scene = bpy.context.scene
    result = authoring.export_assets()
    # Sparse structure is preserved: Blender must not silently bake new keys.
    for exported in result["motion"]["tracks"]:
        target, path, axis, _ = authoring.BINDINGS[exported["binding"]]
        curve = authoring.curves(authoring.control(target)).find(path, index=axis)
        assert len(curve.keyframe_points) == len(exported["keys"])
    assert result["rig"] == json.loads(scene["run_source_rig"])
    foot = authoring.control("left_foot")
    original_name = foot.name
    try:
        foot.name = "My renamed foot control"
        assert authoring.export_assets() == result
    finally:
        foot.name = original_name
    curve = authoring.curves(foot).find("location", index=2)
    saved = [(key.co.copy(), key.handle_left.copy(), key.handle_right.copy())
             for key in curve.keyframe_points]
    try:
        # Shift the whole curve, preserving loop continuity even with only two keys.
        for key, (position, incoming, outgoing) in zip(curve.keyframe_points, saved):
            key.co = (position.x, position.y + 0.01)
            key.handle_left = (incoming.x, incoming.y + 0.01)
            key.handle_right = (outgoing.x, outgoing.y + 0.01)
        curve.update()
        track = authoring.export_track("left_foot_y", scene["cycle_end_frame"] - 1)
        for exported, (position, incoming, outgoing) in zip(track["keys"], saved):
            assert math.isclose(exported["value"], position.y + 0.01, abs_tol=1e-6)
            if "in_handle" in exported:
                assert math.isclose(exported["in_handle"][1], incoming.y + 0.01, abs_tol=1e-6)
            if "out_handle" in exported:
                assert math.isclose(exported["out_handle"][1], outgoing.y + 0.01, abs_tol=1e-6)
        authoring.export(output / "edited")
    finally:
        for key, handles in zip(curve.keyframe_points, saved):
            key.co, key.handle_left, key.handle_right = handles
        curve.update()
    modifier = curve.modifiers.new("NOISE")
    try:
        expect_rejected(authoring, "without modifiers")
    finally:
        curve.modifiers.remove(modifier)
    try:
        foot.delta_location.x = 0.1
        expect_rejected(authoring, "delta transforms")
    finally:
        foot.delta_location.x = 0
    try:
        foot.location.y = 0.1
        expect_rejected(authoring, "XZ plane")
    finally:
        foot.location.y = 0
    try:
        foot.parent = authoring.control("pelvis")
        expect_rejected(authoring, "hierarchy")
    finally:
        foot.parent = None
    old_contact = foot["contact_0_end"]
    old_speed = scene["reference_speed_mps"]
    try:
        foot["contact_0_end"] = 0.35
        scene["reference_speed_mps"] = 3.3
        changed = authoring.export_assets()
        assert changed["motion"]["contacts"][0]["end"] == 0.35
        assert changed["motion"]["reference_speed_mps"] == 3.3
    finally:
        foot["contact_0_end"] = old_contact
        scene["reference_speed_mps"] = old_speed
    compare_values(authoring.export_assets(), result)
    try:
        scene.keyframe_insert('["reference_speed_mps"]', frame=1)
        expect_rejected(authoring, "settings must be static")
    finally:
        scene.animation_data_clear()
    try:
        scene.driver_add('["start_seconds"]')
        expect_rejected(authoring, "settings must be static")
    finally:
        scene.animation_data_clear()
    # Exercise supported interpolation and the smallest valid loop independently
    # of how the user has keyed the current file. Main reloads the saved workspace.
    curve.keyframe_points.clear()
    for interpolation in ("bezier", "linear", "step"):
        value = saved[0][0].y
        authoring.import_track({"binding": "left_foot_y", "keys": [
            {"phase": 0, "value": value, "interpolation": interpolation,
             "out_handle": [1 / 3, value]},
            {"phase": 1, "value": value, "interpolation": "linear",
             "in_handle": [2 / 3, value]},
        ]}, scene["cycle_end_frame"] - 1)
        exported = authoring.export_track("left_foot_y", scene["cycle_end_frame"] - 1)
        assert len(exported["keys"]) == 2
        assert ("out_handle" in exported["keys"][0]) == (interpolation == "bezier")
        authoring.export(output / interpolation)
    print("Blender checks passed: sparse curves, all interpolation modes, two-key loops, "
          "edits, bindings, contacts, settings, unsupported animation/transforms")
