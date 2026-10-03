const std = @import("std");
const audio = @import("src/audio.zig");
const menu = @import("src/menu.zig");
const sdl = @import("src/sdl.zig");
const runtime = @import("src/runtime.zig");
const fs = @import("src/fs.zig");
const delay = @import("src/delay.zig");
const gamepad = @import("src/gamepad.zig");
const allocator = @import("src/allocator.zig").allocator;
const c = sdl.c;

const CatalogClip = struct {
    key: []const u8,
    path: []const u8,
    durationMs: u32,
    volume: f32,
    preload: bool = false,
};

fn initAudio() !void {
    runtime.init(std.testing.io);
    try std.testing.expect(c.SDL_SetHint(c.SDL_HINT_AUDIO_DRIVER, "dummy"));
    try std.testing.expect(c.SDL_Init(c.SDL_INIT_AUDIO | c.SDL_INIT_GAMEPAD));
    errdefer c.SDL_Quit();
    try audio.init();
    errdefer audio.cleanup();
    try std.testing.expect(c.SDL_PauseAudioDevice(audio.device_id));
    const json = try fs.readFileAlloc("sounds.json", std.testing.allocator, 16384);
    defer std.testing.allocator.free(json);
    const catalog = try std.json.parseFromSlice([]const CatalogClip, std.testing.allocator, json, .{});
    defer catalog.deinit();
    for (catalog.value) |clip| {
        if (!clip.preload) continue;
        try audio.preload(clip.key, .{
            .file = clip.path,
            .durationMs = clip.durationMs,
            .volume = clip.volume,
        });
    }
    try std.testing.expectEqual(@as(usize, 8), audio.cached_sounds.count());
}

fn clearDelays() void {
    var keys = delay.delayedActions.keyIterator();
    while (keys.next()) |key| allocator.free(key.*);
    delay.delayedActions.clearAndFree();
}

fn cleanup() void {
    const volume = menu.sound_volume;
    menu.sound_volume = 0;
    menu.close();
    menu.sound_volume = volume;
    clearDelays();
    audio.cleanup();
    c.SDL_Quit();
}

fn clearVoices() !void {
    for (audio.cached_voices) |stream| {
        try std.testing.expect(stream != null);
        try std.testing.expect(c.SDL_ClearAudioStream(stream.?));
    }
}

fn queuedCount() !usize {
    var count: usize = 0;
    for (audio.cached_voices) |stream| {
        try std.testing.expect(stream != null);
        const bytes = c.SDL_GetAudioStreamQueued(stream.?);
        try std.testing.expect(bytes >= 0);
        if (bytes > 0) count += 1;
    }
    return count;
}

fn expectCue(id: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), try queuedCount());
    const clip = audio.cached_sounds.get(id) orelse {
        std.log.err("menu_audio_tests.expectCue: missing test clip '{s}'", .{id});
        return error.MissingClip;
    };
    for (audio.cached_voices) |stream| {
        try std.testing.expect(stream != null);
        const bytes = c.SDL_GetAudioStreamQueued(stream.?);
        if (bytes == 0) continue;
        try std.testing.expectEqual(clip.len, bytes);
    }
}

fn expectNavigation() !c_int {
    try std.testing.expectEqual(@as(usize, 1), try queuedCount());
    for (audio.cached_voices) |stream| {
        try std.testing.expect(stream != null);
        const bytes = c.SDL_GetAudioStreamQueued(stream.?);
        if (bytes == 0) continue;
        for ([_][]const u8{ "ui_navigate_1", "ui_navigate_2", "ui_navigate_3" }) |id| {
            if (bytes == audio.cached_sounds.get(id).?.len) return bytes;
        }
    }
    std.log.err("menu_audio_tests.expectNavigation: no navigation sample was queued", .{});
    return error.WrongCue;
}

fn press(key: c.SDL_Scancode) !void {
    clearDelays();
    menu.beginFrame();
    var keys: [c.SDL_SCANCODE_COUNT]bool = @splat(false);
    keys[key] = true;
    try menu.handleInput(&keys);
}

var actions: usize = 0;
fn confirmAction() !void {
    actions += 1;
}

var submenu_items = [_]menu.Item{
    .{ .label = "Confirm", .shortcut = c.SDL_SCANCODE_C, .kind = .{ .button = confirmAction } },
};

fn openSubmenu() !void {
    menu.push(&submenu_items, .{});
}

fn replaceMenu() !void {
    menu.open(&submenu_items, .{});
}

test "menu cues follow real actions with one sound per transition and varied navigation" {
    try initAudio();
    defer cleanup();
    actions = 0;
    var items = [_]menu.Item{
        .{ .label = "Submenu", .shortcut = c.SDL_SCANCODE_O, .kind = .{ .button = openSubmenu } },
        .{ .label = "Confirm", .shortcut = c.SDL_SCANCODE_C, .kind = .{ .button = confirmAction } },
        .{ .label = "Disabled", .shortcut = c.SDL_SCANCODE_X, .disabled = true, .kind = .{ .button = confirmAction } },
    };
    menu.open(&items, .{});
    try expectCue("ui_open");
    try clearVoices();
    try press(c.SDL_SCANCODE_DOWN);
    const first = try expectNavigation();
    try clearVoices();
    try press(c.SDL_SCANCODE_UP);
    const second = try expectNavigation();
    try std.testing.expect(first != second);
    try clearVoices();
    try press(c.SDL_SCANCODE_RETURN);
    try expectCue("ui_submenu"); // Opening also activates a button; only one cue.
    try clearVoices();
    try press(c.SDL_SCANCODE_DOWN); // One visible item: selection did not change.
    try std.testing.expectEqual(@as(usize, 0), try queuedCount());
    try menu.handleKey(c.SDL_SCANCODE_C, false);
    try expectCue("ui_confirm");
    try std.testing.expectEqual(@as(usize, 1), actions);
    try clearVoices();
    try menu.handleKey(c.SDL_SCANCODE_C, true);
    try std.testing.expectEqual(@as(usize, 0), try queuedCount());
    try menu.back();
    try expectCue("ui_back");
    try clearVoices();
    try menu.handleKey(c.SDL_SCANCODE_X, false);
    try std.testing.expectEqual(@as(usize, 0), try queuedCount());
    menu.close();
    try expectCue("ui_close");
    try clearVoices();
    menu.close();
    try std.testing.expectEqual(@as(usize, 0), try queuedCount());

    var replacement = [_]menu.Item{
        .{ .label = "Replace", .shortcut = c.SDL_SCANCODE_R, .kind = .{ .button = replaceMenu } },
    };
    menu.open(&replacement, .{ .close_on_activate = true });
    try clearVoices();
    try menu.handleKey(c.SDL_SCANCODE_R, false);
    try expectCue("ui_submenu"); // Automatic close + new menu must not double-play.
    const previous_volume = menu.sound_volume;
    defer menu.sound_volume = previous_volume;
    menu.sound_volume = 0;
    try clearVoices();
    try menu.handleKey(c.SDL_SCANCODE_C, false);
    try std.testing.expectEqual(@as(usize, 0), try queuedCount());
    try std.testing.expectEqual(@as(usize, 2), actions);
}

test "value limits remain silent and cancelling an edit emits only the back cue" {
    try initAudio();
    defer cleanup();
    var value = menu.ConfigData{ .value = 1, .step = 1, .min = 0, .max = 1 };
    var items = [_]menu.Item{.{ .label = "Value", .kind = .{ .config = &value } }};
    menu.open(&items, .{});
    try clearVoices();
    try press(c.SDL_SCANCODE_RETURN);
    try expectCue("ui_confirm");
    try clearVoices();
    try press(c.SDL_SCANCODE_UP);
    try std.testing.expectEqual(@as(usize, 0), try queuedCount());
    try press(c.SDL_SCANCODE_DOWN);
    _ = try expectNavigation();
    try std.testing.expectEqual(@as(f32, 0), value.value);
    try clearVoices();
    try press(c.SDL_SCANCODE_ESCAPE);
    try expectCue("ui_back");
    try std.testing.expectEqual(@as(f32, 1), value.value);

    const names = [_][:0]const u8{ "Off", "On" };
    var choice: u8 = 0;
    var cycles = [_]menu.Item{.{
        .label = names[0],
        .kind = .{ .button = confirmAction },
        .cycle_names = &names,
        .cycle_index = &choice,
    }};
    menu.open(&cycles, .{ .minimal_edit = true });
    try clearVoices();
    try press(c.SDL_SCANCODE_RETURN);
    try expectCue("ui_confirm");
    try clearVoices();
    try press(c.SDL_SCANCODE_UP);
    _ = try expectNavigation();
    try std.testing.expectEqual(@as(u8, 1), choice);
    try clearVoices();
    try press(c.SDL_SCANCODE_ESCAPE);
    try expectCue("ui_back");
    try std.testing.expectEqual(@as(u8, 0), choice);
}

test "navigation skips missing and muted variants without losing menu input" {
    try initAudio();
    defer cleanup();
    const missing = audio.cached_sounds.fetchRemove("ui_navigate_1").?;
    defer allocator.free(missing.key);
    defer c.SDL_free(missing.value.buf);
    audio.cached_sounds.getPtr("ui_navigate_2").?.volume = 0;
    var items = [_]menu.Item{
        .{ .label = "First", .kind = .{ .button = confirmAction } },
        .{ .label = "Second", .kind = .{ .button = confirmAction } },
    };
    menu.open(&items, .{});
    for (0..6) |index| {
        try clearVoices();
        try press(c.SDL_SCANCODE_DOWN);
        try std.testing.expectEqual((index + 1) % items.len, menu.focusedIndex());
        try expectCue("ui_navigate_3");
    }
    audio.cached_sounds.getPtr("ui_navigate_3").?.volume = 0;
    try clearVoices();
    try press(c.SDL_SCANCODE_DOWN);
    try std.testing.expectEqual(@as(usize, 1), menu.focusedIndex());
    try std.testing.expectEqual(@as(usize, 0), try queuedCount());
}

test "cached playback bounds overlap reuses streams and releases assets on shutdown" {
    try initAudio();
    defer cleanup();
    const streams = audio.cached_voices;
    const sample = audio.cached_sounds.get("ui_confirm").?;
    // A duplicate ID must not reread its path or replace a live sample.
    try audio.preload("ui_confirm", .{ .file = "does-not-exist.wav", .durationMs = 1 });
    try std.testing.expectEqual(sample.buf, audio.cached_sounds.get("ui_confirm").?.buf);
    for (0..streams.len) |_| try std.testing.expect(audio.playCached("ui_confirm", 0.5));
    try std.testing.expectEqual(streams.len, try queuedCount());
    for (0..100) |_| try std.testing.expect(!audio.playCached("ui_confirm", 0.5));
    try std.testing.expectEqual(streams.len, try queuedCount());
    try std.testing.expect(c.SDL_ResumeAudioDevice(audio.device_id));
    c.SDL_Delay(350);
    try std.testing.expect(c.SDL_PauseAudioDevice(audio.device_id));
    try std.testing.expectEqual(@as(usize, 0), try queuedCount());
    try std.testing.expect(audio.playCached("ui_confirm", 0.5));
    try expectCue("ui_confirm");
    for (streams, audio.cached_voices) |before, after| try std.testing.expectEqual(before, after);
    audio.cleanup(); // Includes active audio; no cached timers can outlive cleanup.
    try std.testing.expectEqual(@as(usize, 0), audio.cached_sounds.count());
    for (audio.cached_voices) |stream| try std.testing.expectEqual(null, stream);
    try std.testing.expect(!audio.playCached("ui_confirm", 1));
    try audio.init();
    try std.testing.expect(c.SDL_PauseAudioDevice(audio.device_id));
    try audio.preload("ui_confirm", .{ .file = "sounds/ui/confirm.wav", .durationMs = 1 });
    try std.testing.expect(audio.playCached("ui_confirm", 0.5));
    try expectCue("ui_confirm");
}

test "virtual gamepad navigation activation and back use the shared sound cues" {
    try initAudio();
    defer cleanup();
    var description = std.mem.zeroes(c.SDL_VirtualJoystickDesc);
    description.version = @sizeOf(c.SDL_VirtualJoystickDesc);
    description.type = c.SDL_JOYSTICK_TYPE_GAMEPAD;
    description.nbuttons = c.SDL_GAMEPAD_BUTTON_COUNT;
    description.button_mask = (@as(u32, 1) << @intCast(c.SDL_GAMEPAD_BUTTON_COUNT)) - 1;
    const id = c.SDL_AttachVirtualJoystick(&description);
    try std.testing.expect(id != 0);
    defer _ = c.SDL_DetachVirtualJoystick(id);
    const pad = c.SDL_OpenGamepad(id) orelse {
        std.log.err("menu_audio_tests: cannot open virtual gamepad: {s}", .{c.SDL_GetError()});
        return error.GamepadUnavailable;
    };
    defer c.SDL_CloseGamepad(pad);
    const joystick = c.SDL_GetGamepadJoystick(pad);
    try std.testing.expect(joystick != null);
    try std.testing.expectEqual(@as(usize, 0), gamepad.assignedGamepads.count());
    try gamepad.assignedGamepads.put(std.testing.allocator, 1, .{ .gamepad = pad, .instanceId = id });
    defer gamepad.assignedGamepads.clearAndFree(std.testing.allocator);
    var items = [_]menu.Item{
        .{ .label = "Confirm", .kind = .{ .button = confirmAction } },
        .{ .label = "Submenu", .kind = .{ .button = openSubmenu } },
    };
    menu.open(&items, .{});
    const keys: [c.SDL_SCANCODE_COUNT]bool = @splat(false);
    const buttons = [_]c_int{ c.SDL_GAMEPAD_BUTTON_DPAD_DOWN, c.SDL_GAMEPAD_BUTTON_SOUTH, c.SDL_GAMEPAD_BUTTON_EAST };
    for (buttons, 0..) |button, index| {
        try clearVoices();
        clearDelays();
        menu.beginFrame();
        try std.testing.expect(c.SDL_SetJoystickVirtualButton(joystick, button, true));
        c.SDL_UpdateGamepads();
        try menu.handleInput(&keys);
        switch (index) {
            0 => {
                _ = try expectNavigation();
            },
            1 => try expectCue("ui_submenu"),
            2 => try expectCue("ui_back"),
            else => unreachable,
        }
        try std.testing.expect(c.SDL_SetJoystickVirtualButton(joystick, button, false));
        c.SDL_UpdateGamepads();
    }
}
