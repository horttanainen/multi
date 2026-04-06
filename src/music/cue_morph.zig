const std = @import("std");

pub fn CueMorph(comptime CueType: type) type {
    return struct {
        from: CueType,
        to: CueType,
        progress: f32 = 1.0,
        morph_beats: f32,
    };
}

pub fn reset(comptime CueType: type, state: *CueMorph(CueType), cue: CueType) void {
    state.from = cue;
    state.to = cue;
    state.progress = 1.0;
}

pub fn setTarget(comptime CueType: type, state: *CueMorph(CueType), cue: CueType) void {
    if (cue == state.to) return;
    const anchor = if (state.progress < 0.5) state.from else state.to;
    state.from = anchor;
    state.to = cue;
    state.progress = 0.0;
}

pub fn advance(comptime CueType: type, state: *CueMorph(CueType), samples_per_beat: f32) void {
    if (state.progress >= 1.0) return;
    if (samples_per_beat <= 0.0) {
        std.log.warn("music.cue_morph.advance: invalid samples_per_beat={d}, snapping morph", .{samples_per_beat});
        state.progress = 1.0;
        return;
    }

    const samples_per_morph = samples_per_beat * state.morph_beats;
    if (samples_per_morph <= 1.0) {
        std.log.warn("music.cue_morph.advance: invalid morph duration samples={d}, snapping morph", .{samples_per_morph});
        state.progress = 1.0;
        return;
    }

    state.progress = @min(1.0, state.progress + 1.0 / samples_per_morph);
}
