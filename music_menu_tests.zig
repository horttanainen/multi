const std = @import("std");
const sdl = @import("src/sdl.zig");
const audio = @import("src/audio.zig");
const music = @import("src/music.zig");
const musicConfigMenu = @import("src/musicConfigMenu.zig");
const menu = @import("src/menu.zig");
const settings = @import("src/settings.zig");
const procedural_hard_techno = @import("src/procedural_hard_techno.zig");
const runtime = @import("src/runtime.zig");
const fs = @import("src/fs.zig");

fn itemNamed(label: []const u8) !*menu.Item {
    for (&musicConfigMenu.main_items) |*item| {
        if (std.mem.eql(u8, item.label, label)) return item;
    }
    std.log.err("music_menu_tests.itemNamed: missing menu item '{s}'", .{label});
    return error.MissingMenuItem;
}

test "music menu preserves the accepted patch while previewing and saving basic playback" {
    runtime.init(std.testing.io);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "agent-temp-files/hard-techno/slider-rollback/menu-test");
    const original_path = settings.settings_path;
    settings.settings_path = "agent-temp-files/hard-techno/slider-rollback/menu-test/settings.json";
    defer settings.settings_path = original_path;
    defer settings.cleanup();
    // Old slider fields are ignored; older saved patches gain the default bass.
    try fs.writeFile(settings.settings_path,
        \\{"music_hard_techno":{"lead":"corrosion","lead_controls":{"distortion":2,"body":0.3}}}
    );
    try settings.init();
    try std.testing.expectEqual(procedural_hard_techno.Lead.corrosion, settings.music_hard_techno.lead);
    try std.testing.expectEqual(@as(f32, 0.65), settings.music_hard_techno.bass_level);
    try std.testing.expectEqual(.snare, settings.music_hard_techno.metal_voice);
    settings.music_seed_enabled = true;
    settings.music_seed = 12345;
    settings.music_style = .hard_techno;
    settings.music_volume = 0.5;
    settings.music_reverb_mix = 0.6;
    settings.applyMusic();
    // Older saved Corrosion choices use the newly selected game voice and phrase.
    try std.testing.expectEqual(.bass_synth, procedural_hard_techno.config.lead);
    try std.testing.expectEqual(.bassline, procedural_hard_techno.config.lead_pattern);
    try std.testing.expectEqual(@as(i8, -24), procedural_hard_techno.config.lead_transpose);
    musicConfigMenu.open(null);
    defer menu.close();

    const expected_labels = [_][]const u8{ "Back", "Reset Changes", "Style: Hard Techno", "Cue", "Volume", "Tempo Scale", "Reverb", "Playback: Loop" };
    try std.testing.expectEqual(expected_labels.len, musicConfigMenu.main_items.len);
    for (expected_labels, musicConfigMenu.main_items) |label, item| {
        try std.testing.expectEqualStrings(label, item.label);
    }
    try std.testing.expect((try itemNamed("Cue")).hidden);
    const tempo = try itemNamed("Tempo Scale");
    const volume = try itemNamed("Volume");
    const reverb = try itemNamed("Reverb");
    tempo.kind.config.value = 1.2;
    volume.kind.config.value = 0.4;
    reverb.kind.config.value = 0.3;
    musicConfigMenu.sync();
    try std.testing.expectEqual(@as(f32, 1.2), settings.music_hard_techno.tempo_scale);
    try std.testing.expectEqual(@as(f32, 0.4), settings.music_volume);
    try std.testing.expectEqual(@as(f32, 0.3), settings.music_reverb_mix);
    var samples: [2048]f32 = undefined;
    procedural_hard_techno.fillBuffer(&samples, 1024);
    const frames = procedural_hard_techno.frames_rendered;
    tempo.kind.config.value = 1.3;
    musicConfigMenu.sync();
    try std.testing.expectEqual(frames, procedural_hard_techno.frames_rendered);
    try std.testing.expectEqual(.bass_synth, procedural_hard_techno.config.lead);
    try std.testing.expectEqual(.bassline, procedural_hard_techno.config.lead_pattern);

    try (try itemNamed("Reset Changes")).kind.button();
    try std.testing.expectEqual(@as(f32, 1), tempo.kind.config.value);
    try std.testing.expectEqual(@as(f32, 0.5), volume.kind.config.value);
    try std.testing.expectEqual(@as(f32, 0.6), reverb.kind.config.value);
    try std.testing.expectEqual(@as(f32, 0.75), settings.music_hard_techno.lead_level);
    try std.testing.expectEqual(@as(f32, 0.65), settings.music_hard_techno.bass_level);
    tempo.kind.config.value = 1.2;
    // These saved patch values have no editor row and must survive menu sync.
    settings.music_hard_techno.bass_level = 0.4;
    settings.music_hard_techno.groove = .machine;
    settings.music_hard_techno.metal_voice = .noise_burst;
    musicConfigMenu.sync();
    const playback = try itemNamed("Playback: Loop");
    try playback.kind.button();
    menu.close();
    settings.music_hard_techno = .{};
    try settings.init();
    try std.testing.expectEqual(music.Style.hard_techno, settings.music_style);
    try std.testing.expectEqual(@as(f32, 1.2), settings.music_hard_techno.tempo_scale);
    try std.testing.expectEqual(@as(f32, 0.4), settings.music_hard_techno.bass_level);
    try std.testing.expectEqual(procedural_hard_techno.Groove.machine, settings.music_hard_techno.groove);
    try std.testing.expectEqual(.noise_burst, settings.music_hard_techno.metal_voice);
    try std.testing.expectEqual(procedural_hard_techno.Arrangement.track, settings.music_hard_techno.arrangement);

    musicConfigMenu.open(null);
    try std.testing.expect((try itemNamed("Cue")).hidden);
    try playback.kind.button();
    try std.testing.expectEqual(procedural_hard_techno.Arrangement.loop, settings.music_hard_techno.arrangement);
    try std.testing.expect((try itemNamed("Cue")).hidden);
    const style = try itemNamed("Style: Hard Techno");
    try style.kind.button(); // Cycle wraps back to Ambient.
    try std.testing.expectEqual(music.Style.ambient, settings.music_style);
    try std.testing.expect(playback.hidden);
    try std.testing.expect(!(try itemNamed("Cue: Dawn")).hidden);
    for (0..5) |_| try style.kind.button();
    try std.testing.expectEqual(music.Style.hard_techno, settings.music_style);
    try std.testing.expect(!playback.hidden);
    try std.testing.expect((try itemNamed("Cue")).hidden);
    menu.close();

    // Escape's cycle restoration writes the original index and calls on_cycle.
    // Exercise those menu callbacks and then close/reload, including tempos
    // that cannot be represented by Hard Techno's narrower range.
    for ([_]f32{ 2.0, 0.2 }) |other_tempo| {
        settings.music_style = .ambient;
        settings.music_bpm = other_tempo;
        settings.music_hard_techno.tempo_scale = 1.1;
        settings.applyMusic();
        musicConfigMenu.open(null);
        const selector = try itemNamed("Style: Ambient");
        selector.cycle_index.?.* = 5;
        selector.on_cycle.?();
        try std.testing.expectEqual(music.Style.hard_techno, settings.music_style);
        try std.testing.expectEqual(@as(f32, 1.1), (try itemNamed("Tempo Scale")).kind.config.value);
        selector.cycle_index.?.* = 0;
        selector.on_cycle.?();
        musicConfigMenu.sync();
        try std.testing.expectEqual(music.Style.ambient, settings.music_style);
        try std.testing.expectEqual(other_tempo, settings.music_bpm);
        menu.close();
        settings.music_bpm = 1;
        settings.music_hard_techno.tempo_scale = 1;
        try settings.init();
        try std.testing.expectEqual(other_tempo, settings.music_bpm);
        try std.testing.expectEqual(@as(f32, 1.1), settings.music_hard_techno.tempo_scale);
    }
}

var measured_peak = std.atomic.Value(u32).init(0);
var measured_samples = std.atomic.Value(u64).init(0);
var invalid_output = std.atomic.Value(bool).init(false);

fn inspectMix(_: ?*anyopaque, _: [*c]const sdl.c.SDL_AudioSpec, buffer: [*c]f32, bytes: c_int) callconv(.c) void {
    if (bytes <= 0) return;
    if (buffer == null) {
        std.log.err("music_menu_tests.inspectMix: missing audio buffer", .{});
        invalid_output.store(true, .release);
        return;
    }
    const count = @as(usize, @intCast(bytes)) / @sizeOf(f32);
    var peak: f32 = 0;
    for (buffer[0..count]) |sample| {
        if (!std.math.isFinite(sample) or @abs(sample) >= 1) {
            std.log.err("music_menu_tests.inspectMix: invalid output sample={d}", .{sample});
            invalid_output.store(true, .release);
            return;
        }
        peak = @max(peak, @abs(sample));
    }
    _ = measured_peak.fetchMax(@bitCast(peak), .monotonic);
    _ = measured_samples.fetchAdd(count, .release);
}

test "SDL callback tolerates live playback edits and master mute silences the actual output" {
    runtime.init(std.testing.io);
    try std.testing.expect(sdl.c.SDL_SetHint(sdl.c.SDL_HINT_AUDIO_DRIVER, "dummy"));
    try std.testing.expect(sdl.c.SDL_Init(sdl.c.SDL_INIT_AUDIO));
    defer sdl.c.SDL_Quit();
    try audio.init();
    defer audio.cleanup();
    settings.music_seed_enabled = true;
    settings.music_seed = 12345;
    settings.music_style = .hard_techno;
    settings.music_hard_techno = .{ .lead = .corrosion };
    settings.music_volume = 0.5;
    settings.applyMusic();
    music.playStyle(.hard_techno);
    try music.init();
    defer music.cleanup();
    measured_peak.store(0, .monotonic);
    measured_samples.store(0, .monotonic);
    invalid_output.store(false, .monotonic);
    try std.testing.expect(sdl.c.SDL_SetAudioPostmixCallback(audio.device_id, inspectMix, null));
    defer _ = sdl.c.SDL_SetAudioPostmixCallback(audio.device_id, null, null);
    for (0..100) |_| {
        if (measured_peak.load(.acquire) > @as(u32, @bitCast(@as(f32, 0.01)))) break;
        sdl.c.SDL_Delay(10);
    }
    try std.testing.expect(measured_samples.load(.acquire) > 0);
    try std.testing.expect(measured_peak.load(.acquire) > @as(u32, @bitCast(@as(f32, 0.01))));
    for (0..60) |index| {
        settings.music_hard_techno.tempo_scale = if (index % 2 == 0) 0.6 else 1.4;
        settings.music_reverb_mix = if (index % 2 == 0) 0.2 else 0.8;
        settings.applyMusic();
        sdl.c.SDL_Delay(5);
    }
    try std.testing.expect(!invalid_output.load(.acquire));
    settings.music_volume = 0;
    settings.applyMusic();
    sdl.c.SDL_Delay(150);
    // Disable the observer before resetting its counters, so no older callback
    // can publish a pre-mute peak after the reset.
    try std.testing.expect(sdl.c.SDL_SetAudioPostmixCallback(audio.device_id, null, null));
    measured_peak.store(0, .monotonic);
    measured_samples.store(0, .monotonic);
    try std.testing.expect(sdl.c.SDL_SetAudioPostmixCallback(audio.device_id, inspectMix, null));
    sdl.c.SDL_Delay(100);
    try std.testing.expect(measured_samples.load(.acquire) > 0);
    try std.testing.expectEqual(@as(u32, 0), measured_peak.load(.acquire));
    try std.testing.expect(!invalid_output.load(.acquire));
}
