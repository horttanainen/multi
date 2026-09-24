#!/usr/bin/env python3
"""Export Curb Rat's editable SVG parts and preview existing solved game poses.

No packages required. Run from any directory:
  python3 scripts/export_character_art.py --preview agent-temp-files/curb-rat-segments
  python3 scripts/export_character_art.py --check

Writes the pack's export/ SVG layers; --check compares without writing. Optional
previews read artifacts/character_animation/*_samples.json and run_polish_poses.json
from `bash scripts/character_animation_check.sh --unit-only`. No animation, IK,
physics or contact solving happens here. Preview output is disposable SVG/HTML.
"""

import argparse
import copy
import html
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / 'character_art/curb_rat_v1'
SVG = 'http://www.w3.org/2000/svg'
ET.register_namespace('', SVG)


def load_assets():
    manifest = json.loads((PACK / 'manifest.json').read_text())
    rig = json.loads((ROOT / 'character_rigs/humanoid.json').read_text())
    if manifest['schema_version'] != 1 or manifest['rig'] != rig['id']:
        raise ValueError('Unsupported art schema or mismatched rig')
    if manifest['weapon_hand']['attachment'] != 'weapon_hand':
        raise ValueError('Artwork must use the gameplay weapon_hand attachment')
    joints = {joint['id']: joint for joint in rig['joints']}
    sources = {}
    for name, part in manifest['parts'].items():
        source = ET.parse(PACK / part['source']).getroot()
        layers = {child.get('id'): child for child in source.findall(f'{{{SVG}}}g')}
        if set(layers) != {'skin', 'fixed'}:
            raise ValueError(f'{name}: expected skin and fixed source groups')
        if [layer['role'] for layer in part['layers']] != ['skin', 'fixed']:
            raise ValueError(f'{name}: layers must draw skin before fixed details')
        points = part['pivot'] + part['axis_end']
        scale = part['meters_per_pixel']
        if not all(math.isfinite(v) for v in points + [scale]) or scale <= 0:
            raise ValueError(f'{name}: non-finite geometry or invalid scale')
        if math.dist(part['pivot'], part['axis_end']) < 1:
            raise ValueError(f'{name}: source axis is degenerate')
        for element in layers['skin'].iter():
            for prop in ('fill', 'stroke'):
                color = element.get(prop, 'none')
                if color == 'none':
                    continue
                if len(color) != 7 or color[0] != '#' or not color[1:3] == color[3:5] == color[5:7]:
                    raise ValueError(f'{name}: skin layer contains non-neutral {color}')
        sources[name] = source
    bindings = {binding['id']: binding for binding in manifest['bindings']}
    if len(bindings) != len(manifest['bindings']):
        raise ValueError('Duplicate binding IDs')
    for binding in bindings.values():
        if binding['part'] not in sources:
            raise ValueError(f"Unknown part: {binding['part']}")
        for joint in [binding['anchor']] + binding['axis']:
            if joint not in joints:
                raise ValueError(f'Unknown rig joint: {joint}')
        if binding['length_mode'] not in ('rig_bone', 'decorative'):
            raise ValueError(f"{binding['id']}: unknown length mode")
        if binding['length_mode'] == 'rig_bone':
            end = joints[binding['axis'][1]]
            if end['parent'] != binding['axis'][0] or binding['anchor'] != binding['axis'][0]:
                raise ValueError(f"{binding['id']}: expected a direct rig bone")
            offset = end['rest_offset']
            part = manifest['parts'][binding['part']]
            length = math.dist(part['pivot'], part['axis_end']) * part['meters_per_pixel']
            if abs(length - math.hypot(offset['x'], offset['y'])) > .00001:
                raise ValueError(f"{binding['id']}: art length differs from rig")
    foot = manifest['parts']['foot']
    toe = joints['left_toe']['rest_offset']
    heel = joints['left_heel']['rest_offset']
    for name, expected in (('toe', [toe['x'], -toe['y']]),
                           ('heel', [toe['x'] + heel['x'], -toe['y'] - heel['y']])):
        actual = [(p - a) * foot['meters_per_pixel'] for p, a in zip(foot['contacts'][name], foot['pivot'])]
        if math.dist(actual, expected) > .00001:
            raise ValueError(f'Foot {name} does not match the rig contact')
    for facing in (False, True):
        order = resolved_order(manifest, facing)
        if sorted(item for item in order if not item.endswith('_weapon')) != sorted(bindings):
            raise ValueError('Draw order must include every binding exactly once')
    return manifest, rig, sources


def resolved_order(manifest, facing):
    near, far = ('left', 'right') if facing else ('right', 'left')
    return [item.replace('near_', near + '_').replace('far_', far + '_') for item in manifest['draw_order']]


def export_layers(manifest, sources, check):
    count = 0
    for name, part in manifest['parts'].items():
        source = sources[name]
        for layer in part['layers']:
            output = ET.Element(f'{{{SVG}}}svg', source.attrib)
            title = ET.SubElement(output, f'{{{SVG}}}title')
            title.text = f"Generated: {part['source']} / {layer['role']}; edit the source"
            output.append(copy.deepcopy(source.find(f"{{{SVG}}}g[@id='{layer['role']}']")))
            ET.indent(output, space='  ')
            text = ET.tostring(output, encoding='unicode') + '\n'
            path = PACK / layer['file']
            if check:
                if not path.exists() or path.read_text() != text:
                    raise ValueError(f'Stale export: {path.relative_to(ROOT)}')
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            count += 1
    print(f"{'Checked' if check else 'Exported'} {count} SVG layers; rig lengths, contacts, colors and draw order valid")


def tinted_part(source, color, depth):
    output = ET.Element(f'{{{SVG}}}g')
    channels = [int(color[i:i+2], 16) for i in (1, 3, 5)]
    for child in source.findall(f'{{{SVG}}}g'):
        layer = copy.deepcopy(child)
        layer.attrib.pop('id')
        if child.get('id') == 'skin':
            for element in layer.iter():
                for prop in ('fill', 'stroke'):
                    paint = element.get(prop, 'none')
                    if paint == 'none':
                        continue
                    value = int(paint[1:3], 16) / 255 * depth
                    element.set(prop, '#' + ''.join(f'{round(c * value):02x}' for c in channels))
        output.append(layer)
    return ET.tostring(output, encoding='unicode')


def xy(point):
    return [point['x'], point['y']]


def pose_joints(sample, rig, local=False):
    pose = sample.get('pose', sample)
    facing = sample.get('facing_right', True)
    body = sample.get('body', {'x': 0, 'y': 0})
    joints = pose['joints']
    if len(joints) != len(rig['joints']):
        raise ValueError('Pose joint count differs from rig')
    if local:
        sign = 1 if facing else -1
        offset = rig['root_from_body']
        points = [[body['x'] + (offset['x'] + p['x']) * sign,
                   body['y'] - offset['y'] - p['y']] for p in joints]
    else:
        points = [xy(p) for p in joints]
    if not all(math.isfinite(v) for point in points for v in point):
        raise ValueError('Pose contains non-finite coordinates')
    return {joint['id']: point for joint, point in zip(rig['joints'], points)}


def part_placement(part, anchor, direction, facing):
    # Uniform art scale is fixed at export time: solved bones never stretch art.
    sign = 1 if facing else -1
    pivot = part['pivot']
    source_angle = math.atan2(part['axis_end'][1] - pivot[1], sign * (part['axis_end'][0] - pivot[0]))
    angle = math.atan2(direction[1], direction[0]) - source_angle
    c, s = math.cos(angle), math.sin(angle)
    scale = part['meters_per_pixel']
    a, b, cc, d = c * scale * sign, s * scale * sign, -s * scale, c * scale
    e = anchor[0] - a * pivot[0] - cc * pivot[1]
    f = anchor[1] - b * pivot[0] - d * pivot[1]
    return f'matrix({a} {b} {cc} {d} {e} {f})'


def weapon_svg(frame):
    root = ET.parse(ROOT / 'weapons/alien_blaster/weapon.svg').getroot()
    # The existing loader consumes these grip/muzzle marker pixels.
    for child in list(root):
        if child.tag == f'{{{SVG}}}rect':
            root.remove(child)
    anchor = frame['weapon']['position']
    angle = math.degrees(frame['weapon']['angle'])
    sign = 1 if frame['weapon_facing_right'] else -1
    content = ''.join(ET.tostring(child, encoding='unicode') for child in root)
    return f'<g transform="translate({anchor["x"]} {anchor["y"]}) rotate({angle}) scale({.00375 * sign} .00375) translate(-49 -64)">{content}</g>'


def render_pose(manifest, rig, sources, joints, facing, color='#f3f3f3', frame=None, overlay=False):
    bindings = {binding['id']: binding for binding in manifest['bindings']}
    weapon_joint = next(a for a in rig['attachments'] if a['id'] == manifest['weapon_hand']['attachment'])['joint']
    weapon_side = weapon_joint.split('_')[0]
    far = 'right' if facing else 'left'
    drawing = []
    for name in resolved_order(manifest, facing):
        if name == 'holstered_weapon':
            if frame and frame['weapon_stowed']:
                drawing.append(weapon_svg(frame))
            continue
        if name.endswith('_weapon'):
            if frame and not frame['weapon_stowed'] and name == weapon_side + '_weapon':
                drawing.append(weapon_svg(frame))
            continue
        binding = bindings[name]
        part_name = binding['part']
        anchor = joints[binding['anchor']]
        start, end = (joints[joint] for joint in binding['axis'])
        direction = [end[0] - start[0], end[1] - start[1]]
        part_facing = facing
        if frame and not frame['weapon_stowed'] and frame.get('weapon_stow_weight', 0) == 0 and name == weapon_side + '_hand_open':
            part_name = manifest['weapon_hand']['part']
            angle = frame['weapon']['angle']
            part_facing = frame['weapon_facing_right']
            sign = 1 if part_facing else -1
            direction = [math.cos(angle) * sign, math.sin(angle) * sign]
        part = manifest['parts'][part_name]
        depth = manifest['far_skin_multiplier'] if binding['depth'] == far else 1
        transform = part_placement(part, anchor, direction, part_facing)
        drawing.append(f'<g transform="{transform}">{tinted_part(sources[part_name], color, depth)}</g>')
    if overlay:
        for joint in rig['joints']:
            p = joints[joint['id']]
            if joint['parent']:
                a = joints[joint['parent']]
                drawing.append(f'<path d="M{a[0]} {a[1]} L{p[0]} {p[1]}" fill="none" stroke="#ff8844" stroke-width=".008"/>')
            drawing.append(f'<circle cx="{p[0]}" cy="{p[1]}" r=".018" fill="#fff2ab" stroke="#ab4930" stroke-width=".004"/>')
    return ''.join(drawing)


def page(title, subtitle, body):
    return f'''<svg xmlns="{SVG}" width="1280" height="1280" viewBox="0 0 1280 1280">
<rect width="1280" height="1280" fill="#161e26"/>
<g font-family="Helvetica, Arial, sans-serif">
<text x="32" y="49" fill="#f3eedb" font-size="32" font-weight="bold">{html.escape(title)}</text>
<text x="32" y="81" fill="#a6b9bc" font-size="16">{html.escape(subtitle)}</text>
{body}
<text x="32" y="1252" fill="#a6b9bc" font-size="14">ART FIT PREVIEW / Existing solved joints. No game renderer integration or collision changes.</text>
</g></svg>'''


def panel(drawing, joints, x, y, width, height, label, scale=150, ground=None, center_x=None):
    pelvis = joints['pelvis']
    # Use the same world scale across poses, centering horizontally on the pelvis.
    origin_x = x + width / 2 - (pelvis[0] if center_x is None else center_x) * scale
    floor = max(joints['left_toe'][1], joints['right_toe'][1]) if ground is None else ground
    origin_y = y + height - 32 - floor * scale
    return f'''<rect x="{x}" y="{y}" width="{width}" height="{height}" rx="12" fill="#eae8d9"/>
<text x="{x+16}" y="{y+28}" fill="#374c56" font-size="16" font-weight="bold">{html.escape(label)}</text>
<g transform="translate({origin_x} {origin_y}) scale({scale})">{drawing}</g>'''


def previews(manifest, rig, sources, output):
    artifacts = ROOT / 'artifacts/character_animation'
    run = json.loads((artifacts / 'run_polish_poses.json').read_text())
    kneel = json.loads((artifacts / 'kneel_samples.json').read_text())
    aims = json.loads((artifacts / 'aim_samples.json').read_text())
    walls = json.loads((artifacts / 'one_hand_slide_samples.json').read_text())
    output.mkdir(parents=True, exist_ok=True)
    cells = []
    for index in range(12):
        sample = run[round(index * len(run) / 12)]
        joints = pose_joints(sample, rig, local=True)
        drawing = render_pose(manifest, rig, sources, joints, True, '#ffffff')
        cells.append(panel(drawing, joints, 24 + index % 4 * 310, 105 + index // 4 * 373, 296, 357,
                           f'{index+1:02} / phase {sample["phase"]:.2f}', scale=143, ground=.3))
    (output / 'run.svg').write_text(page('CURB RAT / RUNNING FIT', 'Twelve frames from the existing run_polish_poses export. Identical scale and ground reference.', ''.join(cells)))
    cases = []
    for facing, color, label in ((True, '#ffffff', 'KNEEL / WHITE'), (False, '#61d9df', 'KNEEL / CYAN / LEFT')):
        sample = [s for s in kneel if s['pose']['facing_right'] == facing][-1]['pose']
        cases.append((pose_joints(sample, rig), facing, color, None, label))
    for action, facing, direction, color, label in (
        ('neutral', True, (1, 0), '#ffffff', 'AIM / RIGHT'),
        ('kneel', False, (-1, 0), '#e889b4', 'KNEEL + AIM / LEFT')):
        sample = next(s for s in aims if s['action'] == action and s['frame']['facing_right'] == facing and tuple(xy(s['direction'])) == direction)
        frame = sample['frame']
        cases.append((pose_joints(frame, rig), facing, color, frame, label))
    for side in (-1, 1):
        frame = next(s['frame'] for s in walls if s['label'] == 'slide' and s['side'] == side)
        cases.append((pose_joints(frame, rig, local=True), frame['facing_right'], '#ffffff', frame, f'WALL SLIDE / {"LEFT" if side == -1 else "RIGHT"} WALL'))
    cells = []
    for index, (joints, facing, color, frame, label) in enumerate(cases):
        drawing = render_pose(manifest, rig, sources, joints, facing, color, frame)
        xs = [point[0] for point in joints.values()]
        if frame:
            weapon = frame['weapon']
            sign = 1 if frame['weapon_facing_right'] else -1
            xs.append(weapon['position']['x'] + sign * math.cos(weapon['angle']) * .42)
        center_x = (min(xs) + max(xs)) / 2
        cells.append(panel(drawing, joints, 24 + index % 3 * 415, 108 + index // 3 * 554, 398, 532, label, scale=170, center_x=center_x))
    (output / 'poses.svg').write_text(page('CURB RAT / ACTION FIT', 'Existing kneel, aim and wall-slide solver exports. White, cyan and pink skin; fixed-color accessories.', ''.join(cells)))
    cells = []
    for index, (name, source) in enumerate(sources.items()):
        x, y = 24 + index % 5 * 249, 110 + index // 5 * 305
        part = manifest['parts'][name]
        width, height = float(source.get('width')), float(source.get('height'))
        scale = min(170 / width, 230 / height)
        art = tinted_part(source, '#ffffff', 1)
        a, b = part['pivot'], part['axis_end']
        cells.append(f'<rect x="{x}" y="{y}" width="235" height="290" rx="10" fill="#eae8d9"/><text x="{x+14}" y="{y+25}" fill="#374c56" font-size="17">{name.replace("_", " ")}</text><g transform="translate({x+118-width*scale/2} {y+45}) scale({scale})">{art}<path d="M{a[0]} {a[1]} L{b[0]} {b[1]}" stroke="#e8753d" stroke-width="1"/><circle cx="{a[0]}" cy="{a[1]}" r="3" fill="#e8753d"/></g>')
    sample = aims[0]['frame']
    joints = pose_joints(sample, rig)
    for index, overlay in enumerate((False, True)):
        drawing = render_pose(manifest, rig, sources, joints, True, '#ffffff', sample, overlay)
        cells.append(panel(drawing, joints, 24 + index * 420, 745, 398, 477, 'ASSEMBLED' if not overlay else 'CURRENT RIG OVERLAY', scale=158))
    cells.append('<text x="880" y="800" fill="#f3eedb" font-size="21">10 editable parts</text><text x="880" y="838" fill="#a6b9bc" font-size="17">20 skin / fixed layers</text><text x="880" y="883" fill="#a6b9bc" font-size="17">Orange = pivot and axis</text><text x="880" y="928" fill="#a6b9bc" font-size="17">Same anatomical gun hand</text><text x="880" y="973" fill="#a6b9bc" font-size="17">No new animation solver</text>')
    (output / 'parts.svg').write_text(page('CURB RAT / ARTICULATED PARTS', 'Joint overlap, editable pivots and separate skin/detail layers. Scale is fixed per part.', ''.join(cells)))
    frames = []
    # Every sixth exported pose gives sixty exact poses, not new interpolation.
    for index, sample in enumerate(run[::6]):
        joints = pose_joints(sample, rig, local=True)
        drawing = render_pose(manifest, rig, sources, joints, True, '#ffffff')
        frames.append(f'<g class="frame" style="display:{"inline" if index == 0 else "none"}">{drawing}</g>')
    # The exported reference clip owns timing; this is an art preview only.
    motion = json.loads((ROOT / 'character_motions/run_reference.json').read_text())
    seconds = motion['cycle_seconds']
    document = f'''<!doctype html><html lang="en"><meta charset="utf-8"><title>Curb Rat segment review</title>
<style>body{{background:#161e26;color:#eee9d9;font:17px system-ui;margin:32px auto;max-width:1100px}} a{{color:#83dbdd}}button,input{{margin:8px}}svg{{background:#eae8d9;border-radius:12px;width:100%;max-height:650px}}img{{width:100%}}</style>
<h1>Curb Rat — articulated art review</h1><p>Offline preview of existing solved run poses, {seconds:g}s per cycle. Review the in-game artwork for final rendering.</p>
<button id="play">Pause</button><label>Frame <input id="frame" type="range" min="0" max="{len(frames)-1}" value="0"></label><label>Speed <select id="speed"><option value="1">1×</option><option value=".25">¼×</option></select></label><label>Size <select id="size"><option value="100%">Close up</option><option value="192px">80 px/m</option></select></label>
<div><svg id="run" xmlns="{SVG}" viewBox="-1.2 -1.9 2.4 2.4"><path d="M-1.2 .3 H1.2" stroke="#b9b5a1" stroke-width=".012"/>{''.join(frames)}</svg></div>
<p><a href="parts.svg">Parts and joint overlay</a> · <a href="run.svg">12 running frames</a> · <a href="poses.svg">Kneeling, aiming and walls</a></p>
<img src="poses.svg" alt="Six solved action poses with segmented artwork">
<script>
const frames=[...document.querySelectorAll('.frame')], slider=document.querySelector('#frame'), button=document.querySelector('#play'), speed=document.querySelector('#speed');
document.querySelector('#size').onchange=event=>{{document.querySelector('#run').style.width=event.target.value;}};
let playing=true, phase=0, last=performance.now(), shown=0;
function show(i){{frames[shown].style.display='none';frames[i].style.display='inline';shown=i;slider.value=i;}}
button.onclick=()=>{{playing=!playing;button.textContent=playing?'Pause':'Play';}};
slider.oninput=()=>{{playing=false;button.textContent='Play';phase=Number(slider.value)/frames.length;show(Number(slider.value));}};
function tick(now){{if(playing){{phase=(phase+(now-last)/1000*Number(speed.value)/{seconds})%1;show(Math.floor(phase*frames.length));}}last=now;requestAnimationFrame(tick);}}requestAnimationFrame(tick);
</script></html>'''
    (output / 'preview.html').write_text(document)
    print(f'Wrote parts.svg, run.svg, poses.svg and preview.html to {output}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Validate and compare exports without writing them')
    parser.add_argument('--preview', type=Path, help='Write SVG/HTML review sheets using existing game test exports')
    args = parser.parse_args()
    manifest, rig, sources = load_assets()
    export_layers(manifest, sources, args.check)
    if args.preview:
        previews(manifest, rig, sources, args.preview)


if __name__ == '__main__':
    main()
