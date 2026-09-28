"""Bootstrap/export the planar run workspace in Blender 4.5 LTS.

Native Blender animation is the source after bootstrap. No custom UI, handlers,
or auto-executed scripts are needed when opening the saved workspace.
"""

import argparse
import json
import math
from pathlib import Path
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import blender_character_tests

ASSETS = {
    "rig": "character_rigs/humanoid.json",
    "motion": "character_motions/run_reference.json",
    "locomotion": "character_locomotion/run.json",
}
# Game +Y up maps to Blender +Z; positive torso lean rotates about Blender +Y.
# Foot angles use the opposite sign because they are ordinary 2D rotations.
BINDINGS = {
    "pelvis_x": ("pelvis", "location", 0, 1),
    "pelvis_y": ("pelvis", "location", 2, 1),
    "torso_angle": ("torso", "rotation_euler", 1, 1),
    "left_foot_x": ("left_foot", "location", 0, 1),
    "left_foot_y": ("left_foot", "location", 2, 1),
    "left_foot_angle": ("left_foot", "rotation_euler", 1, -1),
    "right_foot_x": ("right_foot", "location", 0, 1),
    "right_foot_y": ("right_foot", "location", 2, 1),
    "right_foot_angle": ("right_foot", "rotation_euler", 1, -1),
    "left_hand_x": ("left_hand", "location", 0, 1),
    "left_hand_y": ("left_hand", "location", 2, 1),
    "right_hand_x": ("right_hand", "location", 0, 1),
    "right_hand_y": ("right_hand", "location", 2, 1),
}
INTERPOLATION = {"step": "CONSTANT", "linear": "LINEAR", "bezier": "BEZIER"}
LOCOMOTION_PROPERTIES = (
    "stop_speed_mps", "full_run_speed_mps", "start_seconds", "stop_seconds",
    "turn_seconds", "stride_min", "stride_max", "release_seconds",
)


def read_json(path):
    return json.loads(path.read_text())


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def control(name):
    matches = [obj for obj in bpy.context.scene.objects if obj.get("run_control") == name]
    if len(matches) != 1:
        raise ValueError(f"Expected one control bound to {name}, found {len(matches)}")
    return matches[0]


def curves(obj):
    animation = obj.animation_data
    if animation is None or animation.action is None:
        raise ValueError(f"{obj.name}: missing action")
    action = animation.action
    if len(action.layers) != 1 or len(action.layers[0].strips) != 1:
        raise ValueError(f"{obj.name}: use a single action layer/strip")
    return action.layers[0].strips[0].channelbag(animation.action_slot).fcurves


def property_value(owner, key, value, description, minimum=0.0):
    owner[key] = value
    owner.id_properties_ui(key).update(description=description, min=minimum)


def empty(name, position=(0, 0, 0), parent=None, size=0.07):
    obj = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(obj)
    obj.empty_display_type = "SPHERE"
    obj.empty_display_size = size
    obj.location = position
    obj.parent = parent
    return obj


def point(value):
    return Vector((value["x"], 0, value["y"]))


def line(name, vertices, parent=None, width=0.018, color=(0.8, 0.9, 1, 1)):
    shape = bpy.data.curves.new(name, "CURVE")
    shape.dimensions = "3D"
    shape.bevel_depth = width
    shape.bevel_resolution = 2
    spline = shape.splines.new("POLY")
    spline.points.add(len(vertices) - 1)
    for vertex, position in zip(spline.points, vertices):
        vertex.co = (*position, 1)
    obj = bpy.data.objects.new(name, shape)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = parent
    obj.color = color
    obj.hide_select = True
    return obj


def import_track(track, span):
    name, path, axis, sign = BINDINGS[track["binding"]]
    obj = control(name)
    for key in track["keys"]:
        getattr(obj, path)[axis] = key["value"] * sign
        obj.keyframe_insert(path, index=axis, frame=1 + key["phase"] * span)
    curve = curves(obj).find(path, index=axis)
    for key, handle in zip(track["keys"], curve.keyframe_points):
        handle.interpolation = INTERPOLATION[key["interpolation"]]
        handle.handle_left_type = "FREE"
        handle.handle_right_type = "FREE"
        for source, destination in (("in_handle", "handle_left"), ("out_handle", "handle_right")):
            phase, value = key.get(source, (key["phase"], key["value"]))
            setattr(handle, destination, (1 + phase * span, value * sign))
    curve.update()


def limb_preview(definition, joints, anchors):
    name = definition["id"]
    root_name, middle_name, end_name = (definition[key] for key in ("root", "middle", "end"))
    middle = point(joints[middle_name]["rest_offset"])
    end = middle + point(joints[end_name]["rest_offset"])
    bones = bpy.data.armatures.new(name)
    obj = bpy.data.objects.new(name, bones)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = anchors[root_name]
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    upper = bones.edit_bones.new(middle_name)
    upper.head, upper.tail = (0, 0, 0), middle
    lower = bones.edit_bones.new(end_name)
    lower.head, lower.tail = middle, end
    lower.parent = upper
    lower.use_connect = True
    # Keep local Z perpendicular to the character plane; IK only bends about Z.
    upper.align_roll(Vector((0, 1, 0)))
    lower.align_roll(Vector((0, 1, 0)))
    bpy.ops.object.mode_set(mode="OBJECT")
    obj.select_set(False)
    for bone in obj.pose.bones:
        bone.lock_ik_x = True
        bone.lock_ik_y = True
        bone.ik_stretch = 0
    constraint = obj.pose.bones[end_name].constraints.new("IK")
    constraint.target = control(name.replace("leg", "foot").replace("arm", "hand"))
    constraint.chain_count = 2
    constraint.use_stretch = False
    constraint.iterations = 500
    obj.show_in_front = False
    obj.hide_select = True
    color = (0.22, 0.48, 0.65, 1) if name.startswith("left") else (0.9, 0.72, 0.28, 1)
    for joint_name in (middle_name, end_name):
        bone = bones.bones[joint_name]
        length = bone.length
        segment = line(joint_name + " segment", [(0, -length, 0), (0, 0, 0)], width=0.024, color=color)
        segment.parent = obj
        segment.parent_type = "BONE"
        segment.parent_bone = joint_name
    anchor = empty(end_name, parent=obj, size=0.012)
    anchor.parent_type = "BONE"
    anchor.parent_bone = end_name
    anchor.hide_select = True
    anchors[end_name] = anchor


def build_preview(rig):
    joints = {joint["id"]: joint for joint in rig["joints"]}
    anchors = {"pelvis": control("pelvis")}
    # The torso control is parented to the pelvis, but hand/foot targets are not.
    anchors["chest"] = empty("chest", point(joints["chest"]["rest_offset"]), control("torso"))
    for name in ("neck", "head", "left_shoulder", "right_shoulder"):
        joint = joints[name]
        anchors[name] = empty(name, point(joint["rest_offset"]), anchors[joint["parent"]])
    line("Torso", [(0, 0, 0), point(joints["chest"]["rest_offset"])], control("torso"), 0.032)
    line("Neck", [(0, 0, 0), point(joints["neck"]["rest_offset"])], anchors["chest"])
    radius = rig["head_radius"]
    circle = [(math.sin(i * math.tau / 48) * radius, 0, math.cos(i * math.tau / 48) * radius)
              for i in range(49)]
    line("Head", circle, anchors["head"], 0.016)
    line("Facing", [(radius * 0.6, 0, 0.03), (radius * 1.25, 0, 0.03)], anchors["head"])
    for definition in rig["limbs"]:
        limb_preview(definition, joints, anchors)
    for side in ("left", "right"):
        foot = empty(side + " sole", parent=anchors[side + "_ankle"], size=0.01)
        constraint = foot.constraints.new("COPY_ROTATION")
        constraint.target = control(side + "_foot")
        toe = point(joints[side + "_toe"]["rest_offset"])
        heel = toe + point(joints[side + "_heel"]["rest_offset"])
        line(side + " foot", [(0, 0, 0), toe, heel], foot, 0.02)
        anchors[side + "_toe"] = empty(side + "_toe", toe, foot, 0.01)
        anchors[side + "_heel"] = empty(side + "_heel", heel, foot, 0.01)
    for name, anchor in anchors.items():
        anchor["run_joint"] = name
        if not anchor.get("run_control"):
            anchor.hide_select = True
            anchor.empty_display_size = 0.005
    line("Ground reference", [(-1.4, 0.1, -0.84), (1.4, 0.1, -0.84)], width=0.004)


def workspace():
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "OBJECT"
    scene.display.shading.background_type = "WORLD"
    scene.world.color = (0.025, 0.025, 0.025)
    scene.render.resolution_x, scene.render.resolution_y = 800, 800
    scene.render.resolution_percentage = 100
    camera_data = bpy.data.cameras.new("Preview camera")
    camera = bpy.data.objects.new("Preview camera", camera_data)
    scene.collection.objects.link(camera)
    camera.location = (0, -6, -0.08)
    camera.rotation_euler = (math.pi / 2, 0, 0)
    camera_data.type, camera_data.ortho_scale = "ORTHO", 2.3
    scene.camera = camera
    camera.hide_set(True)
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                space = area.spaces.active
                space.region_3d.view_rotation = Quaternion((1, 0, 0), math.pi / 2)
                space.region_3d.view_perspective = "ORTHO"
                space.region_3d.view_distance = 2.7
                space.region_3d.view_location = (0, 0, -0.08)
                space.shading.color_type = "OBJECT"
                space.overlay.show_floor = False
                space.overlay.show_axis_x = False
                space.overlay.show_axis_y = False
                space.overlay.show_relationship_lines = False
            elif area.type == "PROPERTIES":
                area.spaces.active.context = "OBJECT"
    # Reuse Blender's prepared Animation screen, with curves alongside the pose.
    if bpy.context.window is not None:
        bpy.context.window.workspace = bpy.data.workspaces["Animation"]
        viewports = [area for area in bpy.context.screen.areas if area.type == "VIEW_3D"]
        if len(viewports) > 1:
            min(viewports, key=lambda area: area.width).type = "GRAPH_EDITOR"
    bpy.ops.object.select_all(action="DESELECT")
    control("left_foot").select_set(True)
    bpy.context.view_layer.objects.active = control("left_foot")
    for area in bpy.context.screen.areas:
        if area.type not in ("GRAPH_EDITOR", "DOPESHEET_EDITOR"):
            continue
        region = next(region for region in area.regions if region.type == "WINDOW")
        with bpy.context.temp_override(area=area, region=region):
            if area.type == "GRAPH_EDITOR":
                bpy.ops.graph.view_all()
            else:
                bpy.ops.action.view_all()


def create(path):
    if path.exists():
        raise ValueError(f"Refusing to replace {path}; choose a new bootstrap destination")
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    scene = bpy.context.scene
    assets = {key: read_json(ROOT / value) for key, value in ASSETS.items()}
    for key, asset in assets.items():
        scene["run_source_" + key] = json.dumps(asset)
    scene["run_workspace_version"] = 1
    motion = assets["motion"]
    scene.render.fps = 60
    span = motion["cycle_seconds"] * scene.render.fps
    scene.frame_start, scene.frame_end = 1, round(span)
    property_value(scene, "cycle_end_frame", 1 + span, "Duplicate endpoint; phase 1", 2)
    property_value(scene, "cycle_seconds", motion["cycle_seconds"], "Duration in game seconds", 0.001)
    property_value(scene, "reference_speed_mps", motion["reference_speed_mps"], "Speed of authored stride", 0.001)
    for key in LOCOMOTION_PROPERTIES:
        property_value(scene, key, assets["locomotion"][key], "Runtime locomotion: " + key)
    for name in dict.fromkeys(binding[0] for binding in BINDINGS.values()):
        obj = empty(name)
        obj["run_control"] = name
        obj.show_name = True
        obj.show_in_front = True
        obj.rotation_mode = "XYZ"
        obj.lock_location = (False, True, False) if name != "torso" else (True, True, True)
        obj.lock_rotation = (True, name not in ("torso", "left_foot", "right_foot"), True)
        obj.lock_scale = (True, True, True)
    control("torso").parent = control("pelvis")
    control("torso").empty_display_type = "CIRCLE"
    control("torso").empty_display_size = 0.2
    for track in motion["tracks"]:
        import_track(track, span)
    keying = scene.keying_sets.new(idname="RunControls", name="Run Controls")
    for target, channel, axis, _ in BINDINGS.values():
        keying.paths.add(control(target), channel, index=axis)
    scene.keying_sets.active_index = 0
    contact_counts = {}
    for contact in motion["contacts"]:
        obj = control(contact["limb"].replace("leg", "foot"))
        index = contact_counts.get(contact["limb"], 0)
        contact_counts[contact["limb"]] = index + 1
        for edge in ("start", "end"):
            key = f"contact_{index}_{edge}"
            property_value(obj, key, contact[edge], "Normalized contact phase; end excluded")
            obj.id_properties_ui(key).update(max=1.0)
            marker_frame = round(1 + contact[edge] * span)
            scene.timeline_markers.new(f"{contact['limb']} {edge}", frame=marker_frame)
    build_preview(assets["rig"])
    workspace()
    scene.frame_set(1)
    instructions = bpy.data.texts.new("READ ME")
    instructions.write((ROOT / "character_authoring/README.md").read_text())
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(path))


def export_track(name, span):
    object_name, path, axis, sign = BINDINGS[name]
    obj = control(object_name)
    curve = curves(obj).find(path, index=axis)
    if curve is None or curve.mute or curve.modifiers or curve.sampled_points:
        raise ValueError(f"{name}: use an unmuted keyframe curve without modifiers")
    keys = []
    for index, handle in enumerate(curve.keyframe_points):
        interpolation = next((key for key, value in INTERPOLATION.items() if value == handle.interpolation), None)
        if interpolation is None:
            raise ValueError(f"{name}: only Constant, Linear and Bezier interpolation can export directly")
        key = {
            "phase": (handle.co.x - 1) / span,
            "value": handle.co.y * sign,
            "interpolation": interpolation,
        }
        if index > 0 and curve.keyframe_points[index - 1].interpolation == "BEZIER":
            key["in_handle"] = [(handle.handle_left.x - 1) / span, handle.handle_left.y * sign]
        if index + 1 < len(curve.keyframe_points) and handle.interpolation == "BEZIER":
            key["out_handle"] = [(handle.handle_right.x - 1) / span, handle.handle_right.y * sign]
        keys.append(key)
    return {"binding": name, "keys": keys}


def validate_controls():
    for name in dict.fromkeys(binding[0] for binding in BINDINGS.values()):
        obj = control(name)
        expected_parent = control("pelvis") if name == "torso" else None
        animation = obj.animation_data
        if obj.parent != expected_parent or obj.constraints or obj.rotation_mode != "XYZ":
            raise ValueError(f"{name}: keep the prepared hierarchy and use unconstrained XYZ controls")
        if animation is None or animation.drivers or animation.nla_tracks:
            raise ValueError(f"{name}: drivers and NLA tracks are not supported by direct curve export")
        if animation.action_blend_type != "REPLACE" or animation.action_influence != 1:
            raise ValueError(f"{name}: action must use Replace at full influence")
        if tuple(obj.scale) != (1, 1, 1) or obj.matrix_parent_inverse != Matrix.Identity(4):
            raise ValueError(f"{name}: keep unit scale and the original parent transform")
        if any(obj.delta_location) or any(obj.delta_rotation_euler) or tuple(obj.delta_scale) != (1, 1, 1):
            raise ValueError(f"{name}: delta transforms cannot be exported")
        allowed = {(path, axis) for target, path, axis, _ in BINDINGS.values() if target == name}
        for curve in curves(obj):
            if (curve.data_path, curve.array_index) not in allowed:
                raise ValueError(f"{name}: unsupported animated channel {curve.data_path}[{curve.array_index}]")
        for path in ("location", "rotation_euler"):
            for axis, value in enumerate(getattr(obj, path)):
                if (path, axis) not in allowed and abs(value) > 1e-7:
                    raise ValueError(f"{name}: move only within the XZ plane using the unlocked channels")


def export_assets():
    scene = bpy.context.scene
    if scene.get("run_workspace_version") != 1:
        raise ValueError("Open a prepared run workspace before exporting")
    settings_animation = scene.animation_data
    if settings_animation is not None:
        has_animation = (settings_animation.action is not None or settings_animation.drivers
                         or settings_animation.nla_tracks)
        if has_animation:
            raise ValueError("Scene settings must be static; scene actions, drivers and NLA cannot export")
    validate_controls()
    assets = {key: json.loads(scene["run_source_" + key]) for key in ASSETS}
    if assets["rig"] != read_json(ROOT / ASSETS["rig"]):
        raise ValueError("The game's rig has changed; bootstrap a new workspace before exporting")
    span = scene["cycle_end_frame"] - 1
    if not math.isfinite(span) or span <= 0:
        raise ValueError("cycle_end_frame must be finite and greater than 1")
    motion = assets["motion"]
    motion["cycle_seconds"] = scene["cycle_seconds"]
    motion["reference_speed_mps"] = scene["reference_speed_mps"]
    motion["tracks"] = [export_track(track["binding"], span) for track in motion["tracks"]]
    contact_counts = {}
    for contact in motion["contacts"]:
        obj = control(contact["limb"].replace("leg", "foot"))
        index = contact_counts.get(contact["limb"], 0)
        contact_counts[contact["limb"]] = index + 1
        for edge in ("start", "end"):
            contact[edge] = obj[f"contact_{index}_{edge}"]
    for key in LOCOMOTION_PROPERTIES:
        assets["locomotion"][key] = scene[key]
    return assets


def sample_scene():
    scene = bpy.context.scene
    span = scene["cycle_end_frame"] - 1
    samples = []
    original_frame, original_subframe = scene.frame_current, scene.frame_subframe
    try:
        for index in range(121):
            phase = index / 120
            frame = 1 + phase * span
            scene.frame_set(math.floor(frame), subframe=frame % 1)
            controls = []
            for name, (target, path, axis, sign) in BINDINGS.items():
                controls.append({"control": name, "value": getattr(control(target), path)[axis] * sign})
            joints = []
            for obj in scene.objects:
                if "run_joint" in obj:
                    position = obj.matrix_world.translation
                    joints.append({"joint": obj["run_joint"], "position": {"x": position.x, "y": position.z}})
                if obj.type == "ARMATURE":
                    bone = obj.pose.bones[0]
                    position = obj.matrix_world @ bone.tail
                    joints.append({"joint": bone.name, "position": {"x": position.x, "y": position.z}})
            samples.append({"phase": phase, "controls": controls, "joints": joints})
    finally:
        scene.frame_set(original_frame, subframe=original_subframe)
    return samples


def export(path):
    assets = export_assets()
    samples = sample_scene()
    path.mkdir(parents=True, exist_ok=True)
    for key, filename in ASSETS.items():
        write_json(path / Path(filename).name, assets[key])
    write_json(path / "samples.json", samples)
    print(f"Exported sparse curves and 121 Blender pose samples to {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("create", "export", "check"))
    parser.add_argument("path", type=Path)
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:])
    if args.command == "create":
        create(args.path.resolve())
        return
    if args.command == "check":
        # Regression cases mutate only this background process, never the saved workspace.
        saved_workspace = bpy.data.filepath
        try:
            blender_character_tests.run(sys.modules[__name__], args.path.resolve())
        finally:
            bpy.ops.wm.open_mainfile(filepath=saved_workspace)
    export(args.path.resolve())
    if args.command == "check":
        bpy.context.scene.render.filepath = str(args.path.resolve() / "preview.png")
        bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    main()
