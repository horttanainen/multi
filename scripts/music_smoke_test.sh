#!/bin/bash
set -euo pipefail

# Headless procedural music smoke test.
# Runs every style + cue with accelerated simulation and writes detailed logs.
# Includes:
# - long-form + anti-repetition proxies
# - cue transition behavior checks (A->B->A)
# - cross-seed divergence checks
# - choir high-frequency artifact guardrail

LOG_FILE="${MUSIC_SMOKE_LOG:-/tmp/music_generation_smoke.log}"
PROBE_BIN=".zig-cache/music_probe_smoke_bin"
PLAN_FILE="${MUSIC_SMOKE_PLAN_FILE:-docs/procedural_music_context_2026-04-06_v2.plan.json}"
SPEED_X="${MUSIC_SMOKE_SPEED_X:-100}"
SIM_SECONDS="${MUSIC_SMOKE_SIM_SECONDS:-1200}"      # 20 minutes of simulated music
REPORT_SECONDS="${MUSIC_SMOKE_REPORT_SECONDS:-10}"
MIN_ACHIEVED_SPEED="${MUSIC_SMOKE_MIN_ACHIEVED_SPEED:-50}"
MIN_ACHIEVED_SPEED_CHOIR="${MUSIC_SMOKE_MIN_ACHIEVED_SPEED_CHOIR:-40}"
MIN_LONG_FORM_DIR_CHANGES="${MUSIC_SMOKE_MIN_LONG_FORM_DIR_CHANGES:-3}"
MIN_LONG_FORM_DIR_CHANGES_CHOIR="${MUSIC_SMOKE_MIN_LONG_FORM_DIR_CHANGES_CHOIR:-2}"
MIN_SECTION_TRANSITIONS="${MUSIC_SMOKE_MIN_SECTION_TRANSITIONS:-4}"
MIN_SECTION_DISTINCT_TRANSITIONS="${MUSIC_SMOKE_MIN_SECTION_DISTINCT_TRANSITIONS:-4}"
PINGPONG_ALT_RUN_THRESHOLD="${MUSIC_SMOKE_PINGPONG_ALT_RUN_THRESHOLD:-8}"

TRANSITION_SIM_SECONDS="${MUSIC_SMOKE_TRANSITION_SIM_SECONDS:-180}"
TRANSITION_REPORT_SECONDS="${MUSIC_SMOKE_TRANSITION_REPORT_SECONDS:-5}"
TRANSITION_ONE_AT_SECONDS="${MUSIC_SMOKE_TRANSITION_ONE_AT_SECONDS:-60}"
TRANSITION_TWO_AT_SECONDS="${MUSIC_SMOKE_TRANSITION_TWO_AT_SECONDS:-120}"

DIVERGENCE_SIM_SECONDS="${MUSIC_SMOKE_DIVERGENCE_SIM_SECONDS:-180}"
DIVERGENCE_REPORT_SECONDS="${MUSIC_SMOKE_DIVERGENCE_REPORT_SECONDS:-5}"
DIVERGENCE_SEED_A="${MUSIC_SMOKE_DIVERGENCE_SEED_A:-11235813}"
DIVERGENCE_SEED_B="${MUSIC_SMOKE_DIVERGENCE_SEED_B:-31415926}"
DIVERGENCE_EARLY_SNAPSHOTS="${MUSIC_SMOKE_DIVERGENCE_EARLY_SNAPSHOTS:-8}"

CHOIR_MAX_HF_RATIO="${MUSIC_SMOKE_CHOIR_MAX_HF_RATIO:-0.02}"
CHOIR_MAX_HF_HOT_BLOCK_RATIO="${MUSIC_SMOKE_CHOIR_MAX_HF_HOT_BLOCK_RATIO:-0.05}"

styles=("ambient" "choir" "african_drums" "taiko")

AMBIENT_BASE_CUE="${MUSIC_SMOKE_AMBIENT_BASE_CUE:-0}"
CHOIR_BASE_CUE="${MUSIC_SMOKE_CHOIR_BASE_CUE:-0}"
AFRICAN_DRUMS_BASE_CUE="${MUSIC_SMOKE_AFRICAN_DRUMS_BASE_CUE:-0}"
TAIKO_BASE_CUE="${MUSIC_SMOKE_TAIKO_BASE_CUE:-0}"

probe_style_name() {
  local style="$1"
  if [[ "$style" == "african_drums" ]]; then
    echo "african"
    return
  fi
  echo "$style"
}

require_gt_zero() {
  local value="$1"
  local name="$2"
  if ! awk -v x="$value" 'BEGIN { exit !(x > 0) }'; then
    echo "music_smoke_test: $name must be > 0 (got $value)" >&2
    exit 2
  fi
}

require_ge_zero() {
  local value="$1"
  local name="$2"
  if ! awk -v x="$value" 'BEGIN { exit !(x >= 0) }'; then
    echo "music_smoke_test: $name must be >= 0 (got $value)" >&2
    exit 2
  fi
}

require_integer_ge_zero() {
  local value="$1"
  local name="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "music_smoke_test: $name must be an integer >= 0 (got $value)" >&2
    exit 2
  fi
}

require_cue_range_0_3() {
  local value="$1"
  local name="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "music_smoke_test: $name must be an integer in [0,3] (got $value)" >&2
    exit 2
  fi
  if (( value < 0 || value > 3 )); then
    echo "music_smoke_test: $name must be in [0,3] (got $value)" >&2
    exit 2
  fi
}

require_gt_zero "$SPEED_X" "MUSIC_SMOKE_SPEED_X"
require_gt_zero "$SIM_SECONDS" "MUSIC_SMOKE_SIM_SECONDS"
require_gt_zero "$REPORT_SECONDS" "MUSIC_SMOKE_REPORT_SECONDS"
require_gt_zero "$MIN_ACHIEVED_SPEED" "MUSIC_SMOKE_MIN_ACHIEVED_SPEED"
require_gt_zero "$MIN_ACHIEVED_SPEED_CHOIR" "MUSIC_SMOKE_MIN_ACHIEVED_SPEED_CHOIR"
require_ge_zero "$MIN_LONG_FORM_DIR_CHANGES" "MUSIC_SMOKE_MIN_LONG_FORM_DIR_CHANGES"
require_ge_zero "$MIN_LONG_FORM_DIR_CHANGES_CHOIR" "MUSIC_SMOKE_MIN_LONG_FORM_DIR_CHANGES_CHOIR"
require_gt_zero "$MIN_SECTION_TRANSITIONS" "MUSIC_SMOKE_MIN_SECTION_TRANSITIONS"
require_gt_zero "$MIN_SECTION_DISTINCT_TRANSITIONS" "MUSIC_SMOKE_MIN_SECTION_DISTINCT_TRANSITIONS"
require_gt_zero "$PINGPONG_ALT_RUN_THRESHOLD" "MUSIC_SMOKE_PINGPONG_ALT_RUN_THRESHOLD"
require_gt_zero "$TRANSITION_SIM_SECONDS" "MUSIC_SMOKE_TRANSITION_SIM_SECONDS"
require_gt_zero "$TRANSITION_REPORT_SECONDS" "MUSIC_SMOKE_TRANSITION_REPORT_SECONDS"
require_gt_zero "$TRANSITION_ONE_AT_SECONDS" "MUSIC_SMOKE_TRANSITION_ONE_AT_SECONDS"
require_gt_zero "$TRANSITION_TWO_AT_SECONDS" "MUSIC_SMOKE_TRANSITION_TWO_AT_SECONDS"
require_gt_zero "$DIVERGENCE_SIM_SECONDS" "MUSIC_SMOKE_DIVERGENCE_SIM_SECONDS"
require_gt_zero "$DIVERGENCE_REPORT_SECONDS" "MUSIC_SMOKE_DIVERGENCE_REPORT_SECONDS"
require_gt_zero "$CHOIR_MAX_HF_RATIO" "MUSIC_SMOKE_CHOIR_MAX_HF_RATIO"
require_gt_zero "$CHOIR_MAX_HF_HOT_BLOCK_RATIO" "MUSIC_SMOKE_CHOIR_MAX_HF_HOT_BLOCK_RATIO"
require_integer_ge_zero "$DIVERGENCE_EARLY_SNAPSHOTS" "MUSIC_SMOKE_DIVERGENCE_EARLY_SNAPSHOTS"
require_cue_range_0_3 "$AMBIENT_BASE_CUE" "MUSIC_SMOKE_AMBIENT_BASE_CUE"
require_cue_range_0_3 "$CHOIR_BASE_CUE" "MUSIC_SMOKE_CHOIR_BASE_CUE"
require_cue_range_0_3 "$AFRICAN_DRUMS_BASE_CUE" "MUSIC_SMOKE_AFRICAN_DRUMS_BASE_CUE"
require_cue_range_0_3 "$TAIKO_BASE_CUE" "MUSIC_SMOKE_TAIKO_BASE_CUE"

if ! awk -v a="$TRANSITION_TWO_AT_SECONDS" -v b="$TRANSITION_ONE_AT_SECONDS" 'BEGIN { exit !(a > b) }'; then
  echo "music_smoke_test: MUSIC_SMOKE_TRANSITION_TWO_AT_SECONDS must be > MUSIC_SMOKE_TRANSITION_ONE_AT_SECONDS" >&2
  exit 2
fi

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "music_smoke_test: plan file not found: $PLAN_FILE" >&2
  exit 2
fi

if grep -q "\"v2_roadmap\"" "$PLAN_FILE"; then
  for milestone in M1_macro_form_graph M2_theme_variation_engine M3_transition_composer M4_control_axes_and_runtime_steering M5_eval_upgrade; do
    if ! grep -q "\"$milestone\"" "$PLAN_FILE"; then
      echo "music_smoke_test: plan file missing milestone '$milestone': $PLAN_FILE" >&2
      exit 2
    fi
  done
else
  for topic in realtime_continuous temporal_controls long_form latency_speed game_pmg_gap; do
    if ! grep -q "\"$topic\"" "$PLAN_FILE"; then
      echo "music_smoke_test: plan file missing topic '$topic': $PLAN_FILE" >&2
      exit 2
    fi
  done
fi

WALL_SECONDS="$(awk -v sim="$SIM_SECONDS" -v speed="$SPEED_X" 'BEGIN { printf "%.3f", sim / speed }')"
TRANSITION_WALL_SECONDS="$(awk -v sim="$TRANSITION_SIM_SECONDS" -v speed="$SPEED_X" 'BEGIN { printf "%.3f", sim / speed }')"
DIVERGENCE_WALL_SECONDS="$(awk -v sim="$DIVERGENCE_SIM_SECONDS" -v speed="$SPEED_X" 'BEGIN { printf "%.3f", sim / speed }')"

mkdir -p "$(dirname "$LOG_FILE")"
{
  echo "music_smoke_test started: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "config: speed_x=$SPEED_X sim_seconds=$SIM_SECONDS wall_seconds=$WALL_SECONDS report_seconds=$REPORT_SECONDS"
  echo "config: base_cues ambient=$AMBIENT_BASE_CUE choir=$CHOIR_BASE_CUE african_drums=$AFRICAN_DRUMS_BASE_CUE taiko=$TAIKO_BASE_CUE"
  echo "config: min_achieved_speed_default=$MIN_ACHIEVED_SPEED min_achieved_speed_choir=$MIN_ACHIEVED_SPEED_CHOIR"
  echo "config: min_long_form_dir_changes_default=$MIN_LONG_FORM_DIR_CHANGES min_long_form_dir_changes_choir=$MIN_LONG_FORM_DIR_CHANGES_CHOIR"
  echo "config: m1_min_section_transitions=$MIN_SECTION_TRANSITIONS m1_min_distinct_transitions=$MIN_SECTION_DISTINCT_TRANSITIONS m1_pingpong_alt_run_threshold=$PINGPONG_ALT_RUN_THRESHOLD"
  echo "config: transition_sim_seconds=$TRANSITION_SIM_SECONDS transition_report_seconds=$TRANSITION_REPORT_SECONDS transition_times=${TRANSITION_ONE_AT_SECONDS},${TRANSITION_TWO_AT_SECONDS}"
  echo "config: divergence_sim_seconds=$DIVERGENCE_SIM_SECONDS divergence_report_seconds=$DIVERGENCE_REPORT_SECONDS divergence_seeds=${DIVERGENCE_SEED_A},${DIVERGENCE_SEED_B} divergence_early_snapshots=$DIVERGENCE_EARLY_SNAPSHOTS"
  echo "config: choir_max_hf_ratio=$CHOIR_MAX_HF_RATIO choir_max_hf_hot_block_ratio=$CHOIR_MAX_HF_HOT_BLOCK_RATIO"
  echo "plan_file: $PLAN_FILE"
  echo "log_file: $LOG_FILE"
  echo
} > "$LOG_FILE"

echo "music_smoke_test: compiling probe binary..." | tee -a "$LOG_FILE"
zig build-exe -O ReleaseFast src/music_probe.zig \
  --cache-dir .zig-cache \
  --global-cache-dir .zig-global-cache \
  -femit-bin="$PROBE_BIN" >> "$LOG_FILE" 2>&1

fingerprint_probe_snapshots() {
  local run_log="$1"
  local style="$2"
  local max_lines="$3"
  local probe_style
  probe_style="$(probe_style_name "$style")"

  awk -v style="$probe_style" -v max_lines="$max_lines" '
    $0 ~ ("probe " style " ") {
      line = $0;
      sub(/^.*probe /, "probe ", line);
      sub(/ t=[0-9.]+s/, " t=*s", line);
      print line;
      count += 1;
      if (max_lines > 0 && count >= max_lines) exit;
    }
  ' "$run_log" | sha256sum | awk '{print $1}'
}

count_probe_snapshots() {
  local run_log="$1"
  local style="$2"
  local max_lines="$3"
  local probe_style
  probe_style="$(probe_style_name "$style")"

  awk -v style="$probe_style" -v max_lines="$max_lines" '
    $0 ~ ("probe " style " ") {
      count += 1;
      if (max_lines > 0 && count >= max_lines) exit;
    }
    END { print count + 0; }
  ' "$run_log"
}

analyze_primary_run() {
  local run_log="$1"
  local style="$2"
  local cue="$3"
  local probe_style
  probe_style="$(probe_style_name "$style")"

  last_topic_realtime="FAIL"
  last_topic_temporal="FAIL"
  last_topic_long_form="FAIL"
  last_topic_latency="FAIL"
  last_topic_gap="FAIL"
  last_topic_m1="FAIL"
  last_topic_noise="PASS"
  last_numeric="FAIL"
  last_duration="FAIL"

  last_snapshots="0"
  last_sim_seconds="0"
  last_achieved_speed="0"
  last_non_finite="-1"
  last_chord_total="0"
  last_chord_unique="0"
  last_chord_changes="0"
  last_cadence_span="0"
  last_cadence_changes="0"
  last_dir_i="0"
  last_dir_c="0"
  last_dir_m="0"
  last_dir_changes="0"
  last_section_transition_count="0"
  last_section_distinct_transition_count="0"
  last_section_unique_count="0"
  last_section_pingpong_max_alt_run="0"
  last_section_changes="0"
  last_hf_ratio="0"
  last_hf_hot_ratio="0"

  local non_finite sim_seconds achieved_speed hf_ratio hf_hot_ratio
  non_finite="$(grep -Eo 'non_finite_samples=[0-9]+' "$run_log" | tail -1 | cut -d= -f2 || true)"
  sim_seconds="$(grep -Eo 'sim_seconds=[0-9]+([.][0-9]+)?' "$run_log" | tail -1 | cut -d= -f2 || true)"
  achieved_speed="$(grep -Eo 'achieved_speed_x=[0-9]+([.][0-9]+)?' "$run_log" | tail -1 | cut -d= -f2 || true)"
  hf_ratio="$(grep -Eo 'hf_ratio=[0-9]+([.][0-9]+)?' "$run_log" | tail -1 | cut -d= -f2 || true)"
  hf_hot_ratio="$(grep -Eo 'hf_hot_block_ratio=[0-9]+([.][0-9]+)?' "$run_log" | tail -1 | cut -d= -f2 || true)"
  if [[ -z "$non_finite" ]]; then non_finite="-1"; fi
  if [[ -z "$sim_seconds" ]]; then sim_seconds="0"; fi
  if [[ -z "$achieved_speed" ]]; then achieved_speed="0"; fi
  if [[ -z "$hf_ratio" ]]; then hf_ratio="-1"; fi
  if [[ -z "$hf_hot_ratio" ]]; then hf_hot_ratio="-1"; fi

  local metrics snaps chord_total chord_unique chord_changes dir_i dir_c dir_m dir_changes cad_span cad_changes section_transition_count section_distinct_transition_count section_unique_count section_pingpong_max_alt_run section_changes
  metrics="$(awk -v style="$probe_style" '
    function absf(x) { return x < 0 ? -x : x }
    $0 ~ ("probe " style " ") {
      snaps += 1;
      if ($0 ~ /chord=[0-9]+\/[0-9]+/) {
        chord_field = $0;
        sub(/^.*chord=/, "", chord_field);
        split(chord_field, chord_parts, " ");
        split(chord_parts[1], chord_pair, "/");
        chord_idx = chord_pair[1] + 0;
        chord_total = chord_pair[2] + 0;
        ch[chord_pair[1]] = 1;
        if (chord_seen && chord_idx != prev_chord_idx) chord_changes += 1;
        prev_chord_idx = chord_idx;
        chord_seen = 1;
      }
      if ($0 ~ /dir=[-0-9.]+\/[-0-9.]+\/[-0-9.]+/) {
        dir_field = $0;
        sub(/^.*dir=/, "", dir_field);
        split(dir_field, dir_parts, " ");
        split(dir_parts[1], dir_pair, "/");
        i = dir_pair[1] + 0;
        c = dir_pair[2] + 0;
        mm = dir_pair[3] + 0;
        if (dir_seen) {
          if (absf(i - prev_i) > 0.0005 || absf(c - prev_c) > 0.0005 || absf(mm - prev_m) > 0.0005) {
            dir_changes += 1;
          }
        } else {
          imin = i; imax = i;
          cmin = c; cmax = c;
          mmin = mm; mmax = mm;
        }
        prev_i = i; prev_c = c; prev_m = mm;
        dir_seen = 1;
        if (i < imin) imin = i;
        if (i > imax) imax = i;
        if (c < cmin) cmin = c;
        if (c > cmax) cmax = c;
        if (mm < mmin) mmin = mm;
        if (mm > mmax) mmax = mm;
      }
      if ($0 ~ /cadence=[-0-9.]+->[-0-9.]+/) {
        cad_field = $0;
        sub(/^.*cadence=/, "", cad_field);
        split(cad_field, cad_parts, " ");
        split(cad_parts[1], cad_pair, "->");
        v = cad_pair[2] + 0;
        if (cad_seen) {
          if (absf(v - prev_cad) > 0.01) cad_changes += 1;
        } else {
          cadmin = v; cadmax = v;
        }
        prev_cad = v;
        cad_seen = 1;
        if (v < cadmin) cadmin = v;
        if (v > cadmax) cadmax = v;
      }
      if (match($0, /sec=[0-9]+:[0-9.]+\/[0-9]+\/[0-9]+/)) {
        sec_field = substr($0, RSTART, RLENGTH);
        sub(/sec=/, "", sec_field);
        split(sec_field, sec_parts, ":");
        sec_id = sec_parts[1] + 0;
        split(sec_parts[2], sec_tail, "/");
        sec_transitions = sec_tail[2] + 0;
        sec_distinct = sec_tail[3] + 0;

        if (sec_transitions > max_sec_transitions) max_sec_transitions = sec_transitions;
        if (sec_distinct > max_sec_distinct) max_sec_distinct = sec_distinct;
        section_ids[sec_id] = 1;

        if (sec_seen && sec_id != prev_sec_id) {
          section_changes += 1;
          from_id = prev_sec_id;
          to_id = sec_id;
          if (pingpong_seen && from_id == prev_transition_to && to_id == prev_transition_from) {
            pingpong_alt_run += 1;
          } else {
            pingpong_alt_run = 1;
          }
          if (pingpong_alt_run > pingpong_max_alt_run) pingpong_max_alt_run = pingpong_alt_run;
          prev_transition_from = from_id;
          prev_transition_to = to_id;
          pingpong_seen = 1;
        }
        prev_sec_id = sec_id;
        sec_seen = 1;
      }
    }
    END {
      uniq = 0;
      for (x in ch) uniq += 1;
      sec_uniq = 0;
      for (x in section_ids) sec_uniq += 1;
      idir = dir_seen ? (imax - imin) : 0.0;
      cdir = dir_seen ? (cmax - cmin) : 0.0;
      mdir = dir_seen ? (mmax - mmin) : 0.0;
      cadspan = cad_seen ? (cadmax - cadmin) : 0.0;
      printf "%d %d %d %d %.6f %.6f %.6f %d %.6f %d %d %d %d %d %d\n", snaps, chord_total, uniq, chord_changes, idir, cdir, mdir, dir_changes, cadspan, cad_changes, max_sec_transitions, max_sec_distinct, sec_uniq, pingpong_max_alt_run, section_changes;
    }
  ' "$run_log")"

  read -r snaps chord_total chord_unique chord_changes dir_i dir_c dir_m dir_changes cad_span cad_changes section_transition_count section_distinct_transition_count section_unique_count section_pingpong_max_alt_run section_changes <<< "$metrics"

  local min_speed min_long_form_dir_changes
  min_speed="$MIN_ACHIEVED_SPEED"
  min_long_form_dir_changes="$MIN_LONG_FORM_DIR_CHANGES"
  if [[ "$style" == "choir" ]]; then
    min_speed="$MIN_ACHIEVED_SPEED_CHOIR"
    min_long_form_dir_changes="$MIN_LONG_FORM_DIR_CHANGES_CHOIR"
  fi

  local numeric_ok duration_ok topic_realtime topic_temporal topic_long_form topic_latency topic_gap topic_m1 topic_noise
  numeric_ok=1
  duration_ok=1
  topic_realtime=1
  topic_temporal=1
  topic_long_form=1
  topic_latency=1
  topic_gap=1
  topic_m1=1
  topic_noise=1

  if [[ "$non_finite" != "0" ]]; then
    numeric_ok=0
  fi
  if ! awk -v got="$sim_seconds" -v want="$SIM_SECONDS" 'BEGIN { exit !(got >= want * 0.99) }'; then
    duration_ok=0
  fi

  # PLAN topic: realtime_continuous
  if [[ "$snaps" -lt 20 || "$chord_changes" -lt 3 || "$cad_changes" -lt 3 ]]; then
    topic_realtime=0
  fi

  # PLAN topic: temporal_controls
  if [[ "$chord_total" -gt 1 && "$chord_changes" -lt 3 ]]; then
    topic_temporal=0
  fi
  if ! awk -v span="$cad_span" 'BEGIN { exit !(span >= 1.0) }'; then
    topic_temporal=0
  fi
  if [[ "$cad_changes" -lt 3 ]]; then
    topic_temporal=0
  fi

  # PLAN topic: long_form
  if ! awk -v a="$dir_i" -v b="$dir_c" -v c="$dir_m" 'BEGIN { d=a; if (b>d) d=b; if (c>d) d=c; exit !(d >= 0.05) }'; then
    topic_long_form=0
  fi
  if [[ "$dir_changes" -lt "$min_long_form_dir_changes" ]]; then
    topic_long_form=0
  fi

  # PLAN topic: latency_speed
  if ! awk -v got="$achieved_speed" -v min="$min_speed" 'BEGIN { exit !(got >= min) }'; then
    topic_latency=0
  fi

  # PLAN topic: game_pmg_gap (practical anti-repetition signal)
  if [[ "$chord_total" -gt 1 && "$chord_unique" -lt 2 ]]; then
    topic_gap=0
  fi
  if [[ "$chord_changes" -lt 3 ]]; then
    topic_gap=0
  fi
  if [[ "$numeric_ok" -eq 0 ]]; then
    topic_gap=0
  fi

  # PLAN milestone: M1_macro_form_graph
  if [[ "$section_transition_count" -lt "$MIN_SECTION_TRANSITIONS" ]]; then
    topic_m1=0
  fi
  if [[ "$section_distinct_transition_count" -lt "$MIN_SECTION_DISTINCT_TRANSITIONS" ]]; then
    topic_m1=0
  fi
  if [[ "$section_pingpong_max_alt_run" -ge "$PINGPONG_ALT_RUN_THRESHOLD" ]]; then
    topic_m1=0
  fi

  # Additional topic: persistent high-frequency artifact guardrail (choir only)
  if [[ "$style" == "choir" ]]; then
    if ! awk -v x="$hf_ratio" 'BEGIN { exit !(x >= 0) }'; then
      topic_noise=0
    fi
    if ! awk -v x="$hf_hot_ratio" 'BEGIN { exit !(x >= 0) }'; then
      topic_noise=0
    fi
    if ! awk -v x="$hf_ratio" -v max="$CHOIR_MAX_HF_RATIO" 'BEGIN { exit !(x <= max) }'; then
      topic_noise=0
    fi
    if ! awk -v x="$hf_hot_ratio" -v max="$CHOIR_MAX_HF_HOT_BLOCK_RATIO" 'BEGIN { exit !(x <= max) }'; then
      topic_noise=0
    fi
  fi

  last_topic_realtime="$([[ "$topic_realtime" -eq 1 ]] && echo PASS || echo FAIL)"
  last_topic_temporal="$([[ "$topic_temporal" -eq 1 ]] && echo PASS || echo FAIL)"
  last_topic_long_form="$([[ "$topic_long_form" -eq 1 ]] && echo PASS || echo FAIL)"
  last_topic_latency="$([[ "$topic_latency" -eq 1 ]] && echo PASS || echo FAIL)"
  last_topic_gap="$([[ "$topic_gap" -eq 1 ]] && echo PASS || echo FAIL)"
  last_topic_m1="$([[ "$topic_m1" -eq 1 ]] && echo PASS || echo FAIL)"
  last_topic_noise="$([[ "$topic_noise" -eq 1 ]] && echo PASS || echo FAIL)"
  last_numeric="$([[ "$numeric_ok" -eq 1 ]] && echo PASS || echo FAIL)"
  last_duration="$([[ "$duration_ok" -eq 1 ]] && echo PASS || echo FAIL)"

  last_snapshots="$snaps"
  last_sim_seconds="$sim_seconds"
  last_achieved_speed="$achieved_speed"
  last_non_finite="$non_finite"
  last_chord_total="$chord_total"
  last_chord_unique="$chord_unique"
  last_chord_changes="$chord_changes"
  last_cadence_span="$cad_span"
  last_cadence_changes="$cad_changes"
  last_dir_i="$dir_i"
  last_dir_c="$dir_c"
  last_dir_m="$dir_m"
  last_dir_changes="$dir_changes"
  last_section_transition_count="$section_transition_count"
  last_section_distinct_transition_count="$section_distinct_transition_count"
  last_section_unique_count="$section_unique_count"
  last_section_pingpong_max_alt_run="$section_pingpong_max_alt_run"
  last_section_changes="$section_changes"
  last_hf_ratio="$hf_ratio"
  last_hf_hot_ratio="$hf_hot_ratio"
}

analyze_transition_run() {
  local run_log="$1"
  local style="$2"
  local cue_a="$3"
  local cue_b="$4"
  local probe_style
  probe_style="$(probe_style_name "$style")"

  local transition_metrics
  transition_metrics="$(awk -v style="$probe_style" -v cue_a="$cue_a" -v cue_b="$cue_b" '
    BEGIN {
      events = 0;
      snaps = 0;
      saw_a = 0;
      saw_b = 0;
      morph = 0;
      final_sel = -1;
    }
    /music_probe: cue_transition / {
      events += 1;
    }
    $0 ~ ("probe " style " ") {
      snaps += 1;
      if (match($0, /sel=[0-9]+/)) {
        sel_field = substr($0, RSTART, RLENGTH);
        sub(/sel=/, "", sel_field);
        sel = sel_field + 0;
        if (sel == cue_a + 0) saw_a = 1;
        if (sel == cue_b + 0) saw_b = 1;
        final_sel = sel;
      }
      if (match($0, /cue=[0-9]+->[0-9]+/)) {
        cue_field = substr($0, RSTART, RLENGTH);
        sub(/cue=/, "", cue_field);
        split(cue_field, cue_pair, "->");
        if ((cue_pair[1] + 0) != (cue_pair[2] + 0)) morph = 1;
      }
      if (match($0, / p=[0-9.]+/)) {
        p_field = substr($0, RSTART, RLENGTH);
        sub(/ p=/, "", p_field);
        if ((p_field + 0) < 0.999) morph = 1;
      }
    }
    END {
      printf "%d %d %d %d %d %d\n", events, snaps, saw_a, saw_b, morph, final_sel;
    }
  ' "$run_log")"

  read -r transition_events transition_snaps transition_saw_a transition_saw_b transition_morph transition_final_sel <<< "$transition_metrics"

  last_transition_events="$transition_events"
  local topic_transition=1
  if [[ "$transition_events" -lt 2 ]]; then
    topic_transition=0
  fi
  if [[ "$transition_snaps" -lt 6 ]]; then
    topic_transition=0
  fi
  if [[ "$transition_saw_a" -ne 1 || "$transition_saw_b" -ne 1 ]]; then
    topic_transition=0
  fi
  if [[ "$transition_morph" -ne 1 ]]; then
    topic_transition=0
  fi
  if [[ "$transition_final_sel" -ne "$cue_a" ]]; then
    topic_transition=0
  fi
  last_topic_transition="$([[ "$topic_transition" -eq 1 ]] && echo PASS || echo FAIL)"
}

analyze_cross_seed_divergence() {
  local run_a="$1"
  local run_b="$2"
  local style="$3"

  local snap_count_a snap_count_b
  snap_count_a="$(count_probe_snapshots "$run_a" "$style" 0)"
  snap_count_b="$(count_probe_snapshots "$run_b" "$style" 0)"

  local early_count_a early_count_b
  early_count_a="$(count_probe_snapshots "$run_a" "$style" "$DIVERGENCE_EARLY_SNAPSHOTS")"
  early_count_b="$(count_probe_snapshots "$run_b" "$style" "$DIVERGENCE_EARLY_SNAPSHOTS")"

  local hash_full_a hash_full_b hash_early_a hash_early_b
  hash_full_a="$(fingerprint_probe_snapshots "$run_a" "$style" 0)"
  hash_full_b="$(fingerprint_probe_snapshots "$run_b" "$style" 0)"
  hash_early_a="$(fingerprint_probe_snapshots "$run_a" "$style" "$DIVERGENCE_EARLY_SNAPSHOTS")"
  hash_early_b="$(fingerprint_probe_snapshots "$run_b" "$style" "$DIVERGENCE_EARLY_SNAPSHOTS")"

  local topic_cross_seed=1
  if [[ "$snap_count_a" -lt 8 || "$snap_count_b" -lt 8 ]]; then
    topic_cross_seed=0
  fi
  if [[ "$early_count_a" -lt "$DIVERGENCE_EARLY_SNAPSHOTS" || "$early_count_b" -lt "$DIVERGENCE_EARLY_SNAPSHOTS" ]]; then
    topic_cross_seed=0
  fi
  if [[ "$hash_full_a" == "$hash_full_b" ]]; then
    topic_cross_seed=0
  fi
  if [[ "$hash_early_a" == "$hash_early_b" ]]; then
    topic_cross_seed=0
  fi

  last_cross_seed_full_equal="$([[ "$hash_full_a" == "$hash_full_b" ]] && echo yes || echo no)"
  last_cross_seed_early_equal="$([[ "$hash_early_a" == "$hash_early_b" ]] && echo yes || echo no)"
  last_topic_cross_seed="$([[ "$topic_cross_seed" -eq 1 ]] && echo PASS || echo FAIL)"
}

base_cue_for_style() {
  local style="$1"
  case "$style" in
    ambient) echo "$AMBIENT_BASE_CUE" ;;
    choir) echo "$CHOIR_BASE_CUE" ;;
    african_drums) echo "$AFRICAN_DRUMS_BASE_CUE" ;;
    taiko) echo "$TAIKO_BASE_CUE" ;;
    *)
      echo "music_smoke_test: unknown style '$style'" >&2
      exit 2
      ;;
  esac
}

total_runs=0
passed_runs=0
failed_runs=0
topic_realtime_fail=0
topic_temporal_fail=0
topic_long_form_fail=0
topic_latency_fail=0
topic_gap_fail=0
topic_m1_fail=0
topic_transition_fail=0
topic_cross_seed_fail=0
topic_noise_fail=0

for style in "${styles[@]}"; do
  cue="$(base_cue_for_style "$style")"
    total_runs=$((total_runs + 1))
    cue_next=$(((cue + 1) % 4))
    run_status="PASS"

    run_tmp="$(mktemp)"
    transition_tmp="$(mktemp)"
    divergence_a_tmp="$(mktemp)"
    divergence_b_tmp="$(mktemp)"

    {
      echo
      echo "=== RUN style=$style cue=$cue started $(date -u +"%Y-%m-%dT%H:%M:%SZ") ==="
    } >> "$LOG_FILE"

    if "$PROBE_BIN" "$style" "$cue" "$SPEED_X" "$WALL_SECONDS" "$REPORT_SECONDS" > "$run_tmp" 2>&1; then
      cat "$run_tmp" >> "$LOG_FILE"
      analyze_primary_run "$run_tmp" "$style" "$cue"
    else
      cat "$run_tmp" >> "$LOG_FILE"
      echo "RESULT style=$style cue=$cue status=FAIL reason=probe_execution_failed" | tee -a "$LOG_FILE"
      run_status="FAIL"
      last_topic_realtime="FAIL"
      last_topic_temporal="FAIL"
      last_topic_long_form="FAIL"
      last_topic_latency="FAIL"
      last_topic_gap="FAIL"
      last_topic_m1="FAIL"
      last_topic_transition="FAIL"
      last_topic_cross_seed="FAIL"
      last_topic_noise="FAIL"
      last_numeric="FAIL"
      last_duration="FAIL"
      last_snapshots="0"
      last_sim_seconds="0"
      last_achieved_speed="0"
      last_non_finite="-1"
      last_chord_unique="0"
      last_chord_total="0"
      last_chord_changes="0"
      last_cadence_span="0"
      last_cadence_changes="0"
      last_dir_i="0"
      last_dir_c="0"
      last_dir_m="0"
      last_dir_changes="0"
      last_section_transition_count="0"
      last_section_distinct_transition_count="0"
      last_section_unique_count="0"
      last_section_pingpong_max_alt_run="0"
      last_section_changes="0"
      last_hf_ratio="-1"
      last_hf_hot_ratio="-1"
      last_transition_events="0"
      last_cross_seed_full_equal="unknown"
      last_cross_seed_early_equal="unknown"
    fi

    if [[ "$run_status" == "PASS" ]]; then
      if "$PROBE_BIN" "$style" "$cue" "$SPEED_X" "$TRANSITION_WALL_SECONDS" "$TRANSITION_REPORT_SECONDS" "$DIVERGENCE_SEED_A" "$cue_next" "$TRANSITION_ONE_AT_SECONDS" "$cue" "$TRANSITION_TWO_AT_SECONDS" > "$transition_tmp" 2>&1; then
        cat "$transition_tmp" >> "$LOG_FILE"
        analyze_transition_run "$transition_tmp" "$style" "$cue" "$cue_next"
      else
        cat "$transition_tmp" >> "$LOG_FILE"
        last_topic_transition="FAIL"
        last_transition_events="0"
      fi

      if "$PROBE_BIN" "$style" "$cue" "$SPEED_X" "$DIVERGENCE_WALL_SECONDS" "$DIVERGENCE_REPORT_SECONDS" "$DIVERGENCE_SEED_A" > "$divergence_a_tmp" 2>&1 && \
         "$PROBE_BIN" "$style" "$cue" "$SPEED_X" "$DIVERGENCE_WALL_SECONDS" "$DIVERGENCE_REPORT_SECONDS" "$DIVERGENCE_SEED_B" > "$divergence_b_tmp" 2>&1; then
        cat "$divergence_a_tmp" >> "$LOG_FILE"
        cat "$divergence_b_tmp" >> "$LOG_FILE"
        analyze_cross_seed_divergence "$divergence_a_tmp" "$divergence_b_tmp" "$style"
      else
        cat "$divergence_a_tmp" >> "$LOG_FILE"
        cat "$divergence_b_tmp" >> "$LOG_FILE"
        last_topic_cross_seed="FAIL"
        last_cross_seed_full_equal="unknown"
        last_cross_seed_early_equal="unknown"
      fi
    fi

    [[ "$last_topic_realtime" == "PASS" ]] || run_status="FAIL"
    [[ "$last_topic_temporal" == "PASS" ]] || run_status="FAIL"
    [[ "$last_topic_long_form" == "PASS" ]] || run_status="FAIL"
    [[ "$last_topic_latency" == "PASS" ]] || run_status="FAIL"
    [[ "$last_topic_gap" == "PASS" ]] || run_status="FAIL"
    [[ "$last_topic_m1" == "PASS" ]] || run_status="FAIL"
    [[ "$last_topic_transition" == "PASS" ]] || run_status="FAIL"
    [[ "$last_topic_cross_seed" == "PASS" ]] || run_status="FAIL"
    [[ "$last_topic_noise" == "PASS" ]] || run_status="FAIL"
    [[ "$last_numeric" == "PASS" ]] || run_status="FAIL"
    [[ "$last_duration" == "PASS" ]] || run_status="FAIL"

    if [[ "$run_status" == "PASS" ]]; then
      passed_runs=$((passed_runs + 1))
    else
      failed_runs=$((failed_runs + 1))
    fi

    [[ "$last_topic_realtime" == "PASS" ]] || topic_realtime_fail=$((topic_realtime_fail + 1))
    [[ "$last_topic_temporal" == "PASS" ]] || topic_temporal_fail=$((topic_temporal_fail + 1))
    [[ "$last_topic_long_form" == "PASS" ]] || topic_long_form_fail=$((topic_long_form_fail + 1))
    [[ "$last_topic_latency" == "PASS" ]] || topic_latency_fail=$((topic_latency_fail + 1))
    [[ "$last_topic_gap" == "PASS" ]] || topic_gap_fail=$((topic_gap_fail + 1))
    [[ "$last_topic_m1" == "PASS" ]] || topic_m1_fail=$((topic_m1_fail + 1))
    [[ "$last_topic_transition" == "PASS" ]] || topic_transition_fail=$((topic_transition_fail + 1))
    [[ "$last_topic_cross_seed" == "PASS" ]] || topic_cross_seed_fail=$((topic_cross_seed_fail + 1))
    [[ "$last_topic_noise" == "PASS" ]] || topic_noise_fail=$((topic_noise_fail + 1))

    result_line="$(printf "RESULT style=%s cue=%s status=%s snapshots=%s sim_seconds=%s achieved_speed=%s non_finite=%s chord_unique=%s/%s chord_changes=%s cadence_span=%.3f cadence_changes=%s director_delta=[%.3f,%.3f,%.3f] director_changes=%s section_transitions=%s section_distinct_transitions=%s section_unique=%s section_pingpong_max_alt_run=%s section_changes=%s hf_ratio=%s hf_hot_block_ratio=%s transition_events=%s cross_seed_full_equal=%s cross_seed_early_equal=%s checks={realtime_continuous:%s temporal_controls:%s long_form:%s latency_speed:%s game_pmg_gap:%s m1_macro_form:%s cue_transitions:%s cross_seed_divergence:%s choir_hf_artifact:%s numeric:%s duration:%s}" \
      "$style" "$cue" "$run_status" "$last_snapshots" "$last_sim_seconds" "$last_achieved_speed" "$last_non_finite" "$last_chord_unique" "$last_chord_total" "$last_chord_changes" "$last_cadence_span" "$last_cadence_changes" "$last_dir_i" "$last_dir_c" "$last_dir_m" "$last_dir_changes" "$last_section_transition_count" "$last_section_distinct_transition_count" "$last_section_unique_count" "$last_section_pingpong_max_alt_run" "$last_section_changes" "$last_hf_ratio" "$last_hf_hot_ratio" "$last_transition_events" "$last_cross_seed_full_equal" "$last_cross_seed_early_equal" "$last_topic_realtime" "$last_topic_temporal" "$last_topic_long_form" "$last_topic_latency" "$last_topic_gap" "$last_topic_m1" "$last_topic_transition" "$last_topic_cross_seed" "$last_topic_noise" "$last_numeric" "$last_duration")"
    echo "$result_line" | tee -a "$LOG_FILE"

    rm -f "$run_tmp" "$transition_tmp" "$divergence_a_tmp" "$divergence_b_tmp"
done

{
  echo
  echo "=== SUMMARY ==="
  echo "runs_total=$total_runs runs_passed=$passed_runs runs_failed=$failed_runs"
  echo "topic_realtime_continuous_failures=$topic_realtime_fail"
  echo "topic_temporal_controls_failures=$topic_temporal_fail"
  echo "topic_long_form_failures=$topic_long_form_fail"
  echo "topic_latency_speed_failures=$topic_latency_fail"
  echo "topic_game_pmg_gap_failures=$topic_gap_fail"
  echo "topic_m1_macro_form_failures=$topic_m1_fail"
  echo "topic_cue_transitions_failures=$topic_transition_fail"
  echo "topic_cross_seed_divergence_failures=$topic_cross_seed_fail"
  echo "topic_choir_hf_artifact_failures=$topic_noise_fail"
  if [[ "$failed_runs" -eq 0 ]]; then
    echo "overall=PASS"
  else
    echo "overall=FAIL"
  fi
  echo "music_smoke_test finished: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
} | tee -a "$LOG_FILE"

if [[ "$failed_runs" -ne 0 ]]; then
  exit 1
fi
