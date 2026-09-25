#!/usr/bin/env python3
"""Render techno listening comparisons through the existing music probe.

Run from any directory: python3 agent-tests/hard_techno_audition.py --phase 4
Phases 1/2 reproduce the kick/rumble and percussion comparisons. Phase 3 renders
the full arrangement at three seeds, verifies stems and ending, and cuts previews.
Phase 4 compares three lead tones, checks additive stems, and renders a full track.
Add --lead-set rough to compare the original Razor with Machine and Buzz; output
defaults to a separate phase4/rough directory, preserving earlier auditions.
Use --lead-set industrial for Buzz, Iron and Corrosion in phase4/industrial.
Phase 6 adds bass to Corrosion: before/after mixes, solo bass, full track and stems.
Use --bass-reference PATH with phase 6 to compare an earlier mix against this version.
The reference must be outside --output-dir and must not alias an existing output file.
Phase 5 was the in-game menu work and has no comparison mode here.
Phase 7 compares the old accent with noise-burst/snare replacements, in isolation
and in the Warehouse mix, plus Machine mixes and a complete selected Snare track.
It requires --percussion-reference DIR containing before_mix_raw.wav and
before_metal_raw.wav rendered with seed 12345, Corrosion, bass 0.65 and 25.6 s.
Requires the project's Zig toolchain and ffmpeg. Writes raw/stem WAVs, logs,
constant-gain loudness-matched copies and a JSON receipt to --output-dir.
The default destination is ignored scratch space. No game launch or downloads.
"""

import argparse
from array import array
from contextlib import ExitStack
import json
import math
import re
import subprocess
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from build_guitar_pluck_audition_pack import (  # noqa: E402
    SAMPLE_RATE,
    cue_for_index,
    write_wav,
)

FOUNDATIONS = [
    ("tight", 2.3, 0.28, 0.52, "foundation"),
    ("driving", 3.8, 0.42, 0.65, "foundation"),
    ("crushed", 6.0, 0.50, 0.72, "foundation"),
]
GROOVES = [(name, 2.3, 0.28, 0.52, name)
           for name in ("warehouse", "rolling", "machine")]


def run(command, log_path):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    log_path.write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log_path}")
    return result.stdout + result.stderr


def loudness(path, log_path=None):
    output = run(
        ["ffmpeg", "-hide_banner", "-nostdin", "-i", str(path), "-af",
         "loudnorm=I=-18:TP=-2:LRA=11:print_format=json", "-f", "null", "-"],
        log_path or path.with_suffix(".loudness.log"),
    )
    start, end = output.rfind("{"), output.rfind("}")
    measurement = json.loads(output[start:end + 1])
    integrated = float(measurement["input_i"])
    true_peak = float(measurement["input_tp"])
    if not math.isfinite(integrated) or not math.isfinite(true_peak):
        raise RuntimeError(f"Non-finite loudness measurement for {path}")
    return {"integrated_lufs": integrated, "true_peak_dbtp": true_peak}


def render(output_dir, name, drive, decay, rumble, groove, bus, duration, seed, arrangement="loop",
           lead="off", lead_level=0.75, bass_level=0.0, metal_voice="snare"):
    path = output_dir / f"{name}_{bus}_raw.wav"
    command = [
        "zig", "build", "procedural-music-probe", "-Doptimize=ReleaseFast", "--",
        "hard-techno", "--seed", str(seed), "--arrangement", arrangement,
        "--kick-drive", str(drive), "--kick-decay", str(decay),
        "--rumble", str(rumble), "--groove", groove,
        "--techno-bus", bus, "--out", str(path),
        "--lead", lead, "--lead-level", str(lead_level),
        "--bass-level", str(bass_level),
        "--metal-voice", metal_voice,
    ]
    if duration is not None:
        command.extend(["--duration", str(duration)])
    log = run(command, path.with_suffix(".render.log"))
    stats = [line for line in log.splitlines() if "techno_render:" in line]
    if len(stats) != 1:
        raise RuntimeError(f"Missing render diagnostics for {path}")
    print(stats[0], flush=True)
    sections = [{"name": match[0], "bar": int(match[1]), "frame": int(match[2]),
                 "seconds": float(match[3])} for match in re.findall(
        r"techno_section: name=(\w+) bar=(\d+) frame=(\d+) seconds=([\d.]+)", log)]
    return {
        "name": name, "bus": bus, "drive": drive, "decay": decay,
        "rumble": rumble, "groove": groove, "raw": str(path), "command": command,
        "render_stats": stats[0], "raw_loudness": loudness(path),
        "arrangement": arrangement, "sections": sections, "lead": lead, "lead_level": lead_level,
        "bass_level": bass_level, "metal_voice": metal_voice,
        "bass_notes": int(re.search(r"techno_bass: level=[\d.]+ notes=(\d+)", log).group(1)),
    }


def match_loudness(item, target, output_dir):
    gain = target - item["raw_loudness"]["integrated_lufs"]
    path = output_dir / f"{item['name']}_matched.wav"
    run(["ffmpeg", "-hide_banner", "-nostdin", "-y", "-i", item["raw"],
         "-af", f"volume={gain:.6f}dB", "-c:a", "pcm_s16le", str(path)],
        path.with_suffix(".gain.log"))
    measured = loudness(path)
    if abs(measured["integrated_lufs"] - target) > 0.15:
        raise RuntimeError(f"Loudness matching missed its target: {path}")
    if measured["true_peak_dbtp"] > -1.95:
        raise RuntimeError(f"Matched audio exceeds true-peak ceiling: {path}")
    item.update(matched=str(path), gain_db=gain, matched_loudness=measured)


def preview_pack(output_dir, clips, name):
    order, inputs, filters, segments = [], [], [], []
    position = 0.0
    for index, clip in enumerate(clips):
        cue = cue_for_index(index)
        cue_path = output_dir / f"cue_{index + 1}.wav"
        write_wav(cue_path, cue)
        inputs.extend(["-i", str(cue_path), "-i", clip["path"]])
        cue_label, music_label = f"cue{index}", f"music{index}"
        filters.append(f"[{index * 2}:a]aformat=sample_rates=48000:channel_layouts=stereo[{cue_label}]")
        filters.append(f"[{index * 2 + 1}:a]atrim=start_sample={clip['start_frame']}:"
                       f"end_sample={clip['end_frame']},asetpts=PTS-STARTPTS,"
                       f"apad=pad_dur=0.6,aformat=sample_rates=48000:channel_layouts=stereo[{music_label}]")
        segments.extend([f"[{cue_label}]", f"[{music_label}]"])
        duration = (clip["end_frame"] - clip["start_frame"]) / SAMPLE_RATE
        start = position + len(cue) / SAMPLE_RATE
        position = start + duration + 0.6
        order.append({"cue_beeps": index + 1, "name": clip["name"],
                      "start_seconds": start, "duration_seconds": duration,
                      "source_start_seconds": clip["start_frame"] / SAMPLE_RATE})
    path = output_dir / f"{name}.wav"
    filters.append("".join(segments) + f"concat=n={len(segments)}:v=0:a=1[out]")
    run(["ffmpeg", "-hide_banner", "-nostdin", "-y", *inputs,
         "-filter_complex", ";".join(filters), "-map", "[out]", "-c:a", "pcm_s16le",
         str(path)], output_dir / f"{name}.log")
    return str(path), order


def pcm16(data):
    samples = array("h", data)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def verify_stems(mix, stems):
    max_error = 0
    gains = [item.get("sum_gain", 1.0) for item in stems]
    with ExitStack() as stack:
        readers = [stack.enter_context(wave.open(item["raw"], "rb")) for item in [mix, *stems]]
        frames = readers[0].getnframes()
        for reader in readers:
            if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate(), reader.getnframes()) != (2, 2, SAMPLE_RATE, frames):
                raise RuntimeError("Track/stem WAV format mismatch")
        while True:
            blocks = [pcm16(reader.readframes(8192)) for reader in readers]
            if not blocks[0]:
                break
            if any(len(block) != len(blocks[0]) for block in blocks):
                raise RuntimeError("Track/stem WAV length mismatch")
            if stems:
                max_error = max(max_error, max(abs(values[0] - sum(value * gain for value, gain in zip(values[1:], gains)))
                                               for values in zip(*blocks)))
        if max_error > len(stems) + 1:
            raise RuntimeError(f"Track stems do not sum within PCM quantization: {max_error} LSB")
    return max_error


def verify_track(mix, stems):
    sections = mix["sections"]
    if [s["name"] for s in sections] != [
            "intro", "drive", "contrast", "pressure", "breakdown", "returning", "outro", "finished"]:
        raise RuntimeError("Incomplete or unexpected track section trace")
    for section in sections:
        if section["frame"] != section["bar"] * 76800:
            raise RuntimeError(f"Section is off the 150 BPM bar grid: {section}")
    if "kicks=480 " not in mix["render_stats"]:
        raise RuntimeError("Track did not preserve the intended kick count/break")
    max_error = verify_stems(mix, stems)
    with wave.open(mix["raw"], "rb") as reader:
        frames = reader.getnframes()
        finished = sections[-1]["frame"]
        if frames < finished + SAMPLE_RATE:
            raise RuntimeError("Track lacks the one-second ending check")
        reader.setpos(finished)
        if any(pcm16(reader.readframes(frames - finished))):
            raise RuntimeError("Track output continues after the arranged ending")
        jumps = []
        for section in sections[1:]:
            reader.setpos(section["frame"] - 1)
            samples = pcm16(reader.readframes(2))
            jump = max(abs(samples[2] - samples[0]), abs(samples[3] - samples[1])) / 32768.0
            if jump >= 0.03:
                raise RuntimeError(f"Discontinuity at section {section['name']}: {jump}")
            jumps.append({"section": section["name"], "sample_jump": jump})
    return {"stem_max_error_lsb": max_error if stems else None,
            "section_jumps": jumps, "ending_is_silent": True}


def track_audition(output_dir, seed):
    seeds = list(dict.fromkeys([seed, 54321, 98765, 314159]))[:3]
    mixes = [render(output_dir, f"track_seed_{value}", 2.3, 0.28, 0.52,
                    "warehouse", "mix", None, value, "track") for value in seeds]
    stems = [render(output_dir, "track", 2.3, 0.28, 0.52, "warehouse", bus,
                    None, seed, "track") for bus in ("low_end", "hats", "clap", "metal")]
    validation = [verify_track(item, stems if index == 0 else [])
                  for index, item in enumerate(mixes)]
    if any(item["sections"] != mixes[0]["sections"] for item in [*mixes[1:], *stems]):
        raise RuntimeError("Seed or bus selection changed the section timeline")
    target = min([-18.0] + [item["raw_loudness"]["integrated_lufs"] -
                           item["raw_loudness"]["true_peak_dbtp"] - 2.0 for item in mixes])
    for item in mixes:
        match_loudness(item, target, output_dir)
    # All excerpts retain the full track's single gain. The break stays quieter.
    timeline = {section["name"]: section["frame"] for section in mixes[0]["sections"]}
    clips = [
        {"name": "main_entry", "start_frame": timeline["drive"] - 2 * 76800,
         "end_frame": timeline["drive"] + 4 * 76800},
        {"name": "machine_contrast", "start_frame": timeline["contrast"] - 2 * 76800,
         "end_frame": timeline["contrast"] + 4 * 76800},
        {"name": "break_and_return", "start_frame": timeline["breakdown"] - 2 * 76800,
         "end_frame": timeline["returning"] + 4 * 76800},
        {"name": "ending", "start_frame": timeline["finished"] - 6 * 76800,
         "end_frame": timeline["finished"] + SAMPLE_RATE},
    ]
    for clip in clips:
        clip["path"] = mixes[0]["matched"]
    pack, order = preview_pack(output_dir, clips, "transitions")
    receipt = {"phase": 3, "bpm": 150, "bars": 128, "target_lufs": target,
               "mixes": mixes, "stems": stems, "validation": validation,
               "comparison": pack, "comparison_order": order,
               "note": "Full-track constant gain is preserved in transition previews. "
                       "Technical checks do not establish musical quality."}
    (output_dir / "audition.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Full track: {mixes[0]['matched']}")
    print(f"Transition previews: {pack}")
    return 0


def lead_audition(output_dir, seed, duration, lead_set):
    baseline = render(output_dir, "no_lead", 2.3, 0.28, 0.52, "warehouse", "mix", duration, seed)
    tones, full_tone = {
        "original": (("razor", "hollow", "wide"), "razor"),
        "rough": (("razor", "machine", "buzz"), "buzz"),
        "industrial": (("buzz", "iron", "corrosion"), "corrosion"),
    }[lead_set]
    mixes = [render(output_dir, tone, 2.3, 0.28, 0.52, "warehouse", "mix", duration, seed,
                    lead=tone) for tone in tones]
    stems = [render(output_dir, tone, 2.3, 0.28, 0.52, "warehouse", "lead", duration, seed,
                    lead=tone) for tone in tones]
    rhythm = [render(output_dir, "lead_rhythm", 2.3, 0.28, 0.52, "warehouse", bus, duration, seed,
                     lead="razor") for bus in ("low_end", "percussion")]
    errors = [verify_stems(mix, [*rhythm, stem]) for mix, stem in zip(mixes, stems)]
    target = min([-18.0] + [item["raw_loudness"]["integrated_lufs"] -
                           item["raw_loudness"]["true_peak_dbtp"] - 2.0 for item in [baseline, *mixes]])
    for item in [baseline, *mixes]:
        match_loudness(item, target, output_dir)
    clips = [{"name": item["name"], "path": item["matched"],
              "start_frame": 0, "end_frame": 614400} for item in mixes]
    pack, order = preview_pack(output_dir, clips, "lead_comparison")
    full = render(output_dir, f"{full_tone}_track", 2.3, 0.28, 0.52, "warehouse", "mix", None, seed,
                  "track", lead=full_tone)
    full_stem = render(output_dir, f"{full_tone}_track", 2.3, 0.28, 0.52, "warehouse", "lead", None, seed,
                       "track", lead=full_tone)
    full_baseline = render(output_dir, "no_lead_track", 2.3, 0.28, 0.52, "warehouse", "mix", None, seed, "track")
    full_rhythm = [render(output_dir, "lead_track_rhythm", 2.3, 0.28, 0.52, "warehouse", bus, None, seed,
                         "track", lead="razor") for bus in ("low_end", "percussion")]
    full_check = verify_track(full, [*full_rhythm, full_stem])
    full_target = min(-18.0, full["raw_loudness"]["integrated_lufs"] -
                      full["raw_loudness"]["true_peak_dbtp"] - 2.0)
    match_loudness(full, full_target, output_dir)
    transitions = [{"name": name, "path": full["matched"],
                    "start_frame": start * 76800, "end_frame": end * 76800}
                   for name, start, end in (("lead_entry", 14, 20), ("break_return", 82, 94))]
    transition_pack, transition_order = preview_pack(output_dir, transitions, "lead_transitions")
    receipt = {"phase": 4, "lead_set": lead_set, "bpm": 150, "seed": seed, "duration": duration, "target_lufs": target,
               "mixes": mixes, "stems": stems, "baseline": baseline, "rhythm_stems": rhythm,
               "stem_max_errors_lsb": errors,
               "comparison": pack, "comparison_order": order, "full_track": full,
               "full_stem": full_stem, "full_baseline": full_baseline, "full_rhythm_stems": full_rhythm,
               "full_validation": full_check,
               "transitions": transition_pack, "transition_order": transition_order,
               "note": "Original four-bar motif shared by all tones. Stems retain raw mix gain. "
                       "Technical checks do not establish musical quality."}
    (output_dir / "audition.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Lead comparison: {pack}")
    print(f"Full track: {full['matched']}")
    print(f"Lead transitions: {transition_pack}")
    return 0


def validate_reference(reference_path, output_dir):
    # Validate before rendering: an input inside the destination (or a hardlink
    # to one of its files) could be overwritten before the comparison.
    reference_path = reference_path.resolve()
    if reference_path.is_relative_to(output_dir.resolve()) or any(
            path.is_file() and reference_path.samefile(path) for path in output_dir.iterdir()):
        raise ValueError("Reference must be outside --output-dir and must not alias an existing output file; choose a new output directory")
    with wave.open(str(reference_path), "rb") as reader:
        if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) != (2, 2, SAMPLE_RATE) or reader.getnframes() < 614400:
            raise ValueError("Reference must be stereo 48 kHz PCM16 with at least 12.8 seconds of audio")
    return reference_path


def read_reference(reference_path, output_dir, name):
    reference_path = validate_reference(reference_path, output_dir)
    return {"name": name, "raw": str(reference_path),
            "raw_loudness": loudness(reference_path, output_dir / f"{name}.loudness.log")}


def bass_audition(output_dir, seed, duration, reference_path=None):
    reference = None
    if reference_path is not None:
        reference = read_reference(reference_path, output_dir, "previous_bass")
    baseline = render(output_dir, "before_bass", 2.3, 0.28, 0.52, "warehouse", "mix", duration, seed,
                      lead="corrosion")
    mix = render(output_dir, "with_bass", 2.3, 0.28, 0.52, "warehouse", "mix", duration, seed,
                 lead="corrosion", bass_level=0.65)
    bass = render(output_dir, "bass_solo", 2.3, 0.28, 0.52, "warehouse", "bass", duration, seed,
                  lead="corrosion", bass_level=0.65)
    # Adding bass reserves linear master headroom. Apply that same gain to the
    # old mix for the additive check; the bass-off source itself stays unchanged.
    baseline["sum_gain"] = 1.0 / (1.0 + 0.65 * 0.25)
    loop_error = verify_stems(mix, [baseline, bass])
    comparison_baseline = baseline
    comparison_items = [baseline, mix]
    if reference is not None:
        comparison_baseline = reference
        comparison_items.append(comparison_baseline)
    target = min([-18.0] + [item["raw_loudness"]["integrated_lufs"] -
                           item["raw_loudness"]["true_peak_dbtp"] - 2.0 for item in comparison_items])
    for item in comparison_items:
        match_loudness(item, target, output_dir)
    # The separate solo copy is raised for auditioning; the raw stem above
    # retains the exact mix gain for summing and level comparisons.
    solo_target = min(-18.0, bass["raw_loudness"]["integrated_lufs"] - bass["raw_loudness"]["true_peak_dbtp"] - 2.0)
    match_loudness(bass, solo_target, output_dir)
    pack, order = preview_pack(output_dir, [
        {"name": item["name"], "path": item["matched"], "start_frame": 0, "end_frame": 614400}
        for item in [comparison_baseline, mix]], "bass_comparison")
    full = render(output_dir, "bass_track", 2.3, 0.28, 0.52, "warehouse", "mix", None, seed,
                  "track", lead="corrosion", bass_level=0.65)
    full_baseline = render(output_dir, "before_bass_track", 2.3, 0.28, 0.52, "warehouse", "mix", None, seed,
                           "track", lead="corrosion")
    full_bass = render(output_dir, "bass_track", 2.3, 0.28, 0.52, "warehouse", "bass", None, seed,
                       "track", lead="corrosion", bass_level=0.65)
    full_baseline["sum_gain"] = baseline["sum_gain"]
    full_check = verify_track(full, [full_baseline, full_bass])
    if full_bass["bass_notes"] != 258:
        raise RuntimeError("Bass arrangement changed its intended 258-note score")
    with wave.open(full_bass["raw"], "rb") as reader:
        for start, end in [(0, 8), (81, 88), (125, 128)]:
            reader.setpos(start * 76800)
            if any(pcm16(reader.readframes((end - start) * 76800))):
                raise RuntimeError(f"Bass played in an arranged rest: bars {start}..{end}")
    full_target = min(-18.0, full["raw_loudness"]["integrated_lufs"] - full["raw_loudness"]["true_peak_dbtp"] - 2.0)
    match_loudness(full, full_target, output_dir)
    transitions, transition_order = preview_pack(output_dir, [
        {"name": name, "path": full["matched"], "start_frame": start * 76800, "end_frame": end * 76800}
        for name, start, end in [("bass_entry", 6, 16), ("bass_under_lead_pause", 38, 44),
                                ("break_and_return", 78, 94)]], "bass_transitions")
    receipt = {"phase": 6, "bpm": 150, "seed": seed, "target_lufs": target,
               "baseline": baseline, "mix": mix, "bass": bass, "comparison_baseline": comparison_baseline,
               "loop_stem_max_error_lsb": loop_error, "comparison": pack, "comparison_order": order,
               "full_track": full, "full_baseline": full_baseline, "full_bass": full_bass,
               "full_validation": full_check, "transitions": transitions, "transition_order": transition_order,
               "note": "Before/after mixes are loudness matched. Solo bass has its own audition gain; "
                       "raw stems retain mix gain. Listening remains the sound-quality check."}
    (output_dir / "audition.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Bass comparison: {pack}")
    print(f"Solo bass: {bass['matched']}")
    print(f"Full track: {full['matched']}")
    return 0


def percussion_audition(output_dir, reference_dir):
    # Check both inputs before writing even a measurement log for either one.
    for name in ("before_mix_raw.wav", "before_metal_raw.wav"):
        path = validate_reference(reference_dir / name, output_dir)
        with wave.open(str(path), "rb") as reader:
            if reader.getnframes() != 1228800:
                raise ValueError("Phase 7 references must contain exactly 25.6 seconds")
    baseline = read_reference(reference_dir / "before_mix_raw.wav", output_dir, "previous_mix")
    old_metal = read_reference(reference_dir / "before_metal_raw.wav", output_dir, "previous_accent")
    mixes, solos, machine_mixes, errors = [], [], [], []
    old_metal["sum_gain"] = -1.0
    for tone in ("noise_burst", "snare"):
        mix = render(output_dir, tone, 2.3, 0.28, 0.52, "warehouse", "mix", 25.6, 12345,
                     lead="corrosion", bass_level=0.65, metal_voice=tone)
        solo = render(output_dir, f"{tone}_solo", 2.3, 0.28, 0.52, "warehouse", "metal", 25.6, 12345,
                      lead="corrosion", bass_level=0.65, metal_voice=tone)
        # Replacing only this bus must leave the rest of the accepted mix intact.
        errors.append(verify_stems(mix, [baseline, old_metal, solo]))
        mixes.append(mix)
        solos.append(solo)
        machine_mixes.append(render(output_dir, f"{tone}_machine", 2.3, 0.28, 0.52, "machine", "mix", 25.6, 12345,
                                    lead="corrosion", bass_level=0.65, metal_voice=tone))
    packs, orders = {}, {}
    for name, items in (("percussion_comparison", [baseline, *mixes]),
                        ("accent_comparison", [old_metal, *solos]),
                        ("machine_comparison", machine_mixes)):
        target = min([-18.0] + [item["raw_loudness"]["integrated_lufs"] -
                               item["raw_loudness"]["true_peak_dbtp"] - 2.0 for item in items])
        for item in items:
            match_loudness(item, target, output_dir)
        packs[name], orders[name] = preview_pack(output_dir, [
            {"name": item["name"], "path": item["matched"], "start_frame": 0, "end_frame": 614400}
            for item in items], name)
    full = render(output_dir, "snare_track", 2.3, 0.28, 0.52, "warehouse", "mix", None, 12345,
                  "track", lead="corrosion", bass_level=0.65)
    full_check = verify_track(full, [])
    match_loudness(full, min(-18.0, full["raw_loudness"]["integrated_lufs"] -
                            full["raw_loudness"]["true_peak_dbtp"] - 2.0), output_dir)
    receipt = {"phase": 7, "seed": 12345, "bpm": 150, "baseline": baseline,
               "previous_accent": old_metal, "mixes": mixes, "solos": solos,
               "machine_mixes": machine_mixes, "replacement_errors_lsb": errors,
               "comparisons": packs, "comparison_orders": orders,
               "full_track": full, "full_validation": full_check,
               "note": "Each comparison uses constant-gain loudness matching. Solo accents are raised independently "
                       "for listening; raw stems retain mix gain. Electronic Snare is the selected game default; Noise Burst remains an alternative."}
    (output_dir / "audition.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    for name, path in packs.items():
        print(f"{name}: {path}")
    print(f"Full track: {full['matched']}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", type=int, choices=(1, 2, 3, 4, 6, 7), default=4)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--duration", type=float, help="clip length for phases 1/2/4/6 (default 25.6 seconds)")
    parser.add_argument("--seed", type=int, default=12345)
    parser.add_argument("--bass-reference", type=Path, help="previous mix WAV for the phase 6 listening comparison")
    parser.add_argument("--percussion-reference", type=Path, help="previous mix/metal render directory for phase 7")
    parser.add_argument("--lead-set", choices=("original", "rough", "industrial"), default="original",
                        help="lead comparison for phase 4 (default original)")
    args = parser.parse_args()
    if args.bass_reference is not None and args.phase != 6:
        parser.error("--bass-reference requires --phase 6")
    if (args.percussion_reference is not None) != (args.phase == 7):
        parser.error("--percussion-reference is required for phase 7 and only supported there")
    if args.phase == 7 and (args.duration is not None or args.seed != 12345):
        parser.error("phase 7 compares fixed 25.6-second, seed-12345 reference renders; omit --duration and --seed")
    if args.lead_set != "original" and args.phase != 4:
        parser.error("--lead-set requires --phase 4")
    if args.phase == 3 and args.duration is not None:
        parser.error("phase 3 renders the complete 128-bar arrangement; omit --duration")
    if args.duration is None:
        args.duration = 25.6
    if not math.isfinite(args.duration) or not 12.8 <= args.duration <= 120.0:
        parser.error("duration must be between 12.8 and 120 seconds")
    if not 0 < args.seed < 2**32:
        parser.error("seed must be a nonzero u32")
    default_dir = ROOT / f"agent-temp-files/hard-techno/phase{args.phase}"
    if args.phase == 4 and args.lead_set != "original":
        default_dir = default_dir / args.lead_set
    destination = args.output_dir or default_dir
    output_dir = destination.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    if args.phase == 3:
        return track_audition(output_dir, args.seed)
    if args.phase == 4:
        return lead_audition(output_dir, args.seed, args.duration, args.lead_set)
    if args.phase == 6:
        return bass_audition(output_dir, args.seed, args.duration, args.bass_reference)
    if args.phase == 7:
        return percussion_audition(output_dir, args.percussion_reference)
    candidates = FOUNDATIONS if args.phase == 1 else GROOVES
    mixes = [render(output_dir, *candidate, "mix", args.duration, args.seed)
             for candidate in candidates]
    buses = ("kick", "rumble") if args.phase == 1 else (
        "kick", "rumble", "low_end", "hats", "clap", "metal", "percussion")
    stems = [render(output_dir, *candidates[0], bus, args.duration, args.seed)
             for bus in buses]

    # Measure only with loudnorm; apply constant gain so the dynamics survive.
    # Lower the common target if any candidate would exceed -2 dB true peak.
    target = min([-18.0] + [
        item["raw_loudness"]["integrated_lufs"] -
        item["raw_loudness"]["true_peak_dbtp"] - 2.0 for item in mixes
    ])
    for item in mixes:
        match_loudness(item, target, output_dir)
    clips = [{"name": item["name"], "path": item["matched"],
              "start_frame": 0, "end_frame": 614400} for item in mixes]
    pack_path, order = preview_pack(output_dir, clips, "compare")
    receipt = {
        "phase": args.phase, "bpm": 150, "seed": args.seed, "duration": args.duration,
        "target_lufs": target, "mixes": mixes, "stems": stems,
        "comparison": str(pack_path), "comparison_order": order,
        "note": "Stems retain raw mix gain; matched mixes use constant gain. "
                "Measurements establish signal properties, not musical quality.",
    }
    (output_dir / "audition.json").write_text(
        json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"Listening comparison: {pack_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
