#!/bin/bash
set -euo pipefail

event_count="${1:-3}"
if (($# > 0)); then
    shift
fi
output_dir="artifacts/explosion_perf"
tower_keep_max_frame_us=25000
default_scenarios=(
    air-explosion
    air-explosion-no-visual
    air-death
    ground-explosion
    ground-explosion-no-visual
    ground-death
    tower-keep-player-kill
)
if (($# > 0)); then
    scenarios=("$@")
else
    scenarios=("${default_scenarios[@]}")
fi

mkdir -p "$output_dir"

for scenario in "${scenarios[@]}"; do
    scenario_event_count="$event_count"
    if [[ "$scenario" == "tower-keep-player-kill" ]]; then
        scenario_event_count=1
    fi
    log_path="$output_dir/${scenario}.log"
    zig build -Dexplosion-perf=true run -- \
        --explosion-benchmark "$scenario" \
        --events "$scenario_event_count" >"$log_path" 2>&1

    if rg -q "panic|error:" "$log_path"; then
        echo "Explosion performance scenario '$scenario' logged a panic or error" >&2
        rg "panic|error:" "$log_path" >&2
        exit 1
    fi
    if ! rg -q "perf\.benchmark_complete scenario=$scenario events=$scenario_event_count" "$log_path"; then
        echo "Explosion performance scenario '$scenario' did not complete" >&2
        exit 1
    fi
    if rg -q "(trigger|capture)_giblet_bodies_created=[1-9]" "$log_path"; then
        echo "Explosion performance scenario '$scenario' created giblet bodies on the hot path" >&2
        exit 1
    fi
    if rg -q "trigger_particle_bodies_created=[1-9]" "$log_path"; then
        echo "Explosion performance scenario '$scenario' created particle bodies on the trigger hot path" >&2
        rg "trigger_particle_bodies_created=[1-9]" "$log_path" >&2
        exit 1
    fi
    if [[ "$scenario" != "tower-keep-player-kill" ]] && rg -q "texture_migrations=[1-9]" "$log_path"; then
        echo "Explosion performance scenario '$scenario' migrated a texture on the hot path" >&2
        exit 1
    fi
    if [[ "$scenario" == "tower-keep-player-kill" ]]; then
        maximum_frame_us="$(awk '
            /perf\.player_death_summary/ {
                for (field = 1; field <= NF; field += 1) {
                    if ($field ~ /^max_frame_us=/) {
                        split($field, value, "=")
                        print value[2]
                        exit
                    }
                }
            }
        ' "$log_path")"
        if [[ -z "$maximum_frame_us" ]]; then
            echo "Explosion performance scenario '$scenario' did not report a player-death maximum frame" >&2
            exit 1
        fi
        if ((maximum_frame_us > tower_keep_max_frame_us)); then
            echo "Explosion performance scenario '$scenario' exceeded ${tower_keep_max_frame_us}us: ${maximum_frame_us}us" >&2
            exit 1
        fi
    fi

    rg "perf\.(benchmark_|player_death_summary|player_death_creation|gravestone_spawn|surface_cutout|surface_texture_update|surface_collider_update)|perf\.explosion id=.*stage=(pressure_build|pressure_visual_capture|explosion_visual_capture|pressure_field|entity_damage|player_pressure|total)" "$log_path"

    awk '
        /perf\.benchmark_event_begin/ {
            event += 1
            frames = 0
            total = 0
            render = 0
            maximum = 0
            capture = 1
            next
        }
        /perf\.benchmark_event_end/ {
            if (frames > 0) {
                printf "perf.benchmark_frames event=%d frames=%d avg_total_us=%d avg_render_us=%d max_total_us=%d\n", event, frames, total / frames, render / frames, maximum
            }
            capture = 0
            next
        }
        capture && /perf\.frame/ {
            frame_total = 0
            frame_render = 0
            for (field = 1; field <= NF; field += 1) {
                if ($field ~ /^total_us=/) {
                    split($field, value, "=")
                    frame_total = value[2]
                }
                if ($field ~ /^render_us=/) {
                    split($field, value, "=")
                    frame_render = value[2]
                }
            }
            if (frame_total == 0) next
            frames += 1
            total += frame_total
            render += frame_render
            if (frame_total > maximum) maximum = frame_total
        }
    ' "$log_path"
done
