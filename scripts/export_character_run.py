#!/usr/bin/env python3
"""Reproduce the phase-one runtime assets from the accepted, calculated run study.

No external packages. Fit foot/hand controls with cubic Bezier segments, checking
0.1 mm / 0.0001 rad error at 64 interior points of each accepted segment.
Pelvis and torso retain their original cubic Bezier handles. The archived dense
motion is never written by this exporter.
"""
import json
import math
from functools import cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = json.loads((ROOT / 'tests/fixtures/character_run_source.json').read_text())
PELVIS_HEIGHT = 0.84
TOLERANCE = 0.0001


def evaluate(curve, phase):
    for a, b, c, d in curve:
        if phase > d[0]:
            continue
        lo, hi = 0.0, 1.0
        for _ in range(40):
            t = (lo + hi) / 2
            q = 1 - t
            x = q**3*a[0] + 3*q*q*t*b[0] + 3*q*t*t*c[0] + t**3*d[0]
            if x < phase:
                lo = t
            else:
                hi = t
        t = (lo + hi) / 2
        q = 1 - t
        return q**3*a[1] + 3*q*q*t*b[1] + 3*q*t*t*c[1] + t**3*d[1]
    return curve[-1][-1][1]


def rotate(point, angle):
    c, s = math.cos(angle), math.sin(angle)
    return [point[0]*c-point[1]*s, point[0]*s+point[1]*c]


def add(a, b):
    return [a[0]+b[0], a[1]+b[1]]


@cache
def targets(phase):
    p = phase % 1
    tracks = SOURCE['tracks']
    pelvis_y = evaluate(tracks['pelvis_y_half_cycle'], p % .5)-PELVIS_HEIGHT
    lean = evaluate(tracks['torso_lean_half_cycle'], p % .5)
    chest = add([0, pelvis_y], rotate([0, .43], -lean))
    values = {'pelvis_x': 0, 'pelvis_y': pelvis_y, 'torso_angle': lean}
    for side, offset in SOURCE['leg_phase_offsets'].items():
        q = (p + offset) % 1
        if q < SOURCE['duty_fraction']:
            beta = evaluate(tracks['stance_foot_angle'], q)
            toe = [.45-q*SOURCE['cycle_seconds']*SOURCE['reference_speed_mps'], -PELVIS_HEIGHT]
            ankle = add(toe, rotate([-.15, .075], beta))
        else:
            beta = evaluate(tracks['swing_foot_angle'], q)
            ankle = [evaluate(tracks['swing_ankle_x'], q), evaluate(tracks['swing_ankle_y'], q)-PELVIS_HEIGHT]
        # Shoulder rest offsets rotate with the torso in the game rig.
        shoulder = add(chest, rotate([.008 if side == 'left' else -.008, -.02], -lean))
        upper = -math.pi/2+evaluate(tracks['arm_swing'], q)
        fore = upper+evaluate(tracks['elbow_flex'], q)
        hand = add(add(shoulder, rotate([.29, 0], upper)), rotate([.26, 0], fore))
        values.update({f'{side}_foot_x': ankle[0], f'{side}_foot_y': ankle[1],
                       f'{side}_foot_angle': beta, f'{side}_hand_x': hand[0], f'{side}_hand_y': hand[1]})
    return values


def curve_boundaries(binding):
    # Keep source segment boundaries, including stance/swing changes and wrapping.
    # Unrelated tracks and the twelve comparison poses do not add runtime keys.
    side = binding.split('_')[0]
    offset = SOURCE['leg_phase_offsets'][side]
    phases = {0., 1.}
    if '_foot_' in binding:
        swing = 'swing_foot_angle' if binding.endswith('angle') else 'swing_ankle_' + binding[-1]
        sources = [('stance_foot_angle', -offset), (swing, -offset)]
    else:
        sources = [(name, shift) for name in ('pelvis_y_half_cycle', 'torso_lean_half_cycle') for shift in (0, .5)]
        sources.extend((name, -offset) for name in ('arm_swing', 'elbow_flex'))
    for name, shift in sources:
        for segment in SOURCE['tracks'][name]:
            for point in (segment[0], segment[3]):
                phases.add(round((point[0]+shift) % 1, 12))
    return sorted(phases)


def append_fitted_segment(binding, keys, end):
    start = keys[-1]['phase']
    first, last = keys[-1]['value'], targets(end)[binding]
    span = end-start
    # One-sided derivatives retain source corners at contact/segment boundaries.
    h = min(span*.001, .000001)
    start_slope = (-3*first+4*targets(start+h)[binding]-targets(start+2*h)[binding])/(2*h)
    end_slope = (3*last-4*targets(end-h)[binding]+targets(end-2*h)[binding])/(2*h)
    outgoing = first+start_slope*span/3
    incoming = last-end_slope*span/3
    maximum_error = 0
    for index in range(1, 65):
        t = index/65
        q = 1-t
        value = q**3*first+3*q*q*t*outgoing+3*q*t*t*incoming+t**3*last
        maximum_error = max(maximum_error, abs(value-targets(start+span*t)[binding]))
    if maximum_error > TOLERANCE:
        if span < .000002:
            raise ValueError(f'Cannot fit {binding} within tolerance and the runtime minimum key spacing')
        middle = (start+end)/2
        append_fitted_segment(binding, keys, middle)
        append_fitted_segment(binding, keys, end)
        return
    # Handles at thirds make Bezier time linear; the runtime still evaluates the
    # same phase/value handle representation used for directly authored curves.
    keys[-1]['interpolation'] = 'bezier'
    keys[-1]['out_handle'] = [start+span/3, outgoing]
    keys.append({'phase': end, 'value': last, 'interpolation': 'linear',
                 'in_handle': [end-span/3, incoming]})


def fitted_track(binding):
    phases = curve_boundaries(binding)
    keys = [{'phase': 0., 'value': targets(0)[binding], 'interpolation': 'linear'}]
    for end in phases[1:]:
        append_fitted_segment(binding, keys, end)
    return {'binding': binding, 'keys': keys}


def bezier_track(binding, source, value_offset=0):
    keys = []
    for offset in (0, .5):
        for a, b, c, d in SOURCE['tracks'][source]:
            if not keys:
                keys.append({'phase': a[0]+offset, 'value': a[1]+value_offset, 'interpolation': 'bezier'})
            keys[-1]['out_handle'] = [b[0]+offset, b[1]+value_offset]
            keys.append({'phase': d[0]+offset, 'value': d[1]+value_offset, 'interpolation': 'bezier',
                         'in_handle': [c[0]+offset, c[1]+value_offset]})
    keys[-1]['interpolation'] = 'linear'
    return {'binding': binding, 'keys': keys}


def point(value):
    return {'x': value[0], 'y': value[1]}


def knee(ankle):
    distance = math.hypot(*ankle)
    height = math.sqrt(.46**2-distance**2/4)
    return [ankle[0]/2-ankle[1]/distance*height, ankle[1]/2+ankle[0]/distance*height]


def make_rig():
    joints = [{'id': 'pelvis', 'parent': None, 'rest_offset': point([0, 0])}]
    for name, parent, offset in [('chest','pelvis',[0,.43]), ('neck','chest',[0,.08]), ('head','neck',[0,.105])]:
        joints.append({'id': name, 'parent': parent, 'rest_offset': point(offset)})
    limbs = []
    neutral = {'pelvis_x': 0, 'pelvis_y': 0, 'torso_angle': 0}
    for side, x in [('left', .12), ('right', -.12)]:
        ankle = [x, .075-PELVIS_HEIGHT]
        bend = knee(ankle)
        offsets = [('shoulder','chest',[.008 if side == 'left' else -.008,-.02]),
                   ('elbow',f'{side}_shoulder',[0,-.29]), ('hand',f'{side}_elbow',[.26,0]),
                   ('knee','pelvis',bend), ('ankle',f'{side}_knee',[ankle[0]-bend[0],ankle[1]-bend[1]]),
                   ('toe',f'{side}_ankle',[.15,-.075]), ('heel',f'{side}_toe',[-.22,0])]
        for name, parent, offset in offsets:
            joints.append({'id': f'{side}_{name}', 'parent': parent, 'rest_offset': point(offset)})
        for name, root, middle, end, sign in [('leg','pelvis',f'{side}_knee',f'{side}_ankle',1),
                                            ('arm',f'{side}_shoulder',f'{side}_elbow',f'{side}_hand',-1)]:
            limbs.append({'id': f'{side}_{name}', 'root': root, 'middle': middle, 'end': end,
                          'bend_sign': sign, 'min_bend_radians': .001, 'max_bend_radians': math.pi-.001})
        neutral.update({f'{side}_foot_x': x, f'{side}_foot_y': ankle[1], f'{side}_foot_angle': 0,
                        f'{side}_hand_x': .1+(.008 if side == 'left' else -.008), f'{side}_hand_y': -.09})
    return {'schema_version': 1, 'id': 'humanoid_v1', 'distance_unit': 'meters', 'angle_unit': 'radians',
            'coordinates': 'x_forward_y_up', 'root_from_body': point([0, PELVIS_HEIGHT-.3]),
            'joints': joints, 'limbs': limbs, 'head_radius': .105, 'line_width': .032,
            'attachments': [{'id': 'weapon_hand', 'joint': 'right_hand', 'local_offset': point([0,0])},
                            {'id': 'grapple_hand', 'joint': 'left_hand', 'local_offset': point([0,0])}],
            'neutral_controls': [{'binding': name, 'value': value} for name, value in neutral.items()]}


def main():
    tracks = [fitted_track(name) for name in targets(0) if name not in ('pelvis_x','pelvis_y','torso_angle')]
    tracks += [{'binding': 'pelvis_x', 'keys': [{'phase': 0, 'value': 0, 'interpolation': 'step'},
                                              {'phase': 1, 'value': 0, 'interpolation': 'linear'}]},
               bezier_track('pelvis_y', 'pelvis_y_half_cycle', -PELVIS_HEIGHT),
               bezier_track('torso_angle', 'torso_lean_half_cycle')]
    motion = {'schema_version': 1, 'id': 'run_reference_v1', 'rig_id': 'humanoid_v1',
              'time_unit': 'seconds', 'distance_unit': 'meters', 'angle_unit': 'radians',
              'coordinates': 'x_forward_y_up', 'cycle_seconds': .6, 'reference_speed_mps': 3.2,
              'loop': True, 'tracks': tracks,
              'contacts': [{'limb': 'left_leg', 'start': 0, 'end': .36},
                           {'limb': 'right_leg', 'start': .5, 'end': .86}]}
    for path, value in [('character_rigs/humanoid.json', make_rig()), ('character_motions/run_reference.json', motion)]:
        (ROOT/path).write_text(json.dumps(value, indent=2)+'\n')
    print(f'Exported rig and run: {sum(len(t["keys"]) for t in tracks)} keys across {len(tracks)} controls.')


if __name__ == '__main__':
    main()
