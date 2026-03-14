const std = @import("std");
const background_paint = @import("background_paint.zig");
const menu = @import("menu.zig");
const settings = @import("settings.zig");
const state = @import("state.zig");

// --- ConfigData for each tweakable parameter ---
var spin_rotation_config = menu.ConfigData{ .value = 0, .step = 0.1, .min = 0, .max = 6.28, .repeat_delay_ms = 75 };
var spin_speed_config = menu.ConfigData{ .value = 0.5, .step = 0.05, .min = 0, .max = 2.0, .repeat_delay_ms = 75 };
var contrast_config = menu.ConfigData{ .value = 2.0, .step = 0.1, .min = 0.5, .max = 5.0, .repeat_delay_ms = 75 };
var spin_amount_config = menu.ConfigData{ .value = 0.4, .step = 0.02, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var pixel_filter_config = menu.ConfigData{ .value = 250, .step = 10, .min = 50, .max = 800, .repeat_delay_ms = 75 };
var offset_x_config = menu.ConfigData{ .value = 0, .step = 0.01, .min = -0.5, .max = 0.5, .repeat_delay_ms = 75 };
var offset_y_config = menu.ConfigData{ .value = 0, .step = 0.01, .min = -0.5, .max = 0.5, .repeat_delay_ms = 75 };

// HSV controls for 3 colours
var c1_h_config = menu.ConfigData{ .value = 0, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var c1_s_config = menu.ConfigData{ .value = 0.7, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var c1_v_config = menu.ConfigData{ .value = 0.6, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var c2_h_config = menu.ConfigData{ .value = 0, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var c2_s_config = menu.ConfigData{ .value = 0.7, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var c2_v_config = menu.ConfigData{ .value = 0.6, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var c3_h_config = menu.ConfigData{ .value = 0, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var c3_s_config = menu.ConfigData{ .value = 0.7, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var c3_v_config = menu.ConfigData{ .value = 0.6, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };

// Algorithm selection state
var swirl_type_value: u8 = 0;
var noise_type_value: u8 = 0;
var color_mode_value: u8 = 0;

const SWIRL_COUNT = 8;
const NOISE_COUNT = 8;
const COLOR_COUNT = 8;

const swirl_names = [SWIRL_COUNT][:0]const u8{
    "Swirl: None",
    "Swirl: Paint Mix",
    "Swirl: Kaleidoscope",
    "Swirl: Radial Ripple",
    "Swirl: Double Spiral",
    "Swirl: Diamond Warp",
    "Swirl: Tunnel",
    "Swirl: Wobble",
};
const noise_names = [NOISE_COUNT][:0]const u8{
    "Noise: None",
    "Noise: Sine Turbulence",
    "Noise: Domain Warp",
    "Noise: Cellular",
    "Noise: Marble",
    "Noise: Plasma",
    "Noise: Ridged",
    "Noise: Wood Grain",
};
const color_names = [COLOR_COUNT][:0]const u8{
    "Color: None",
    "Color: Distance Blend",
    "Color: Angle-based",
    "Color: Gradient",
    "Color: Rings",
    "Color: Duotone",
    "Color: Neon",
    "Color: Posterize",
};

var items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBack }, .font = .medium },
    .{ .label = "Spin Rotation", .kind = .{ .config = &spin_rotation_config }, .font = .medium },
    .{ .label = "Spin Speed", .kind = .{ .config = &spin_speed_config }, .font = .medium },
    .{ .label = "Contrast", .kind = .{ .config = &contrast_config }, .font = .medium },
    .{ .label = "Spin Amount", .kind = .{ .config = &spin_amount_config }, .font = .medium },
    .{ .label = "Pixel Filter", .kind = .{ .config = &pixel_filter_config }, .font = .medium },
    .{ .label = "Offset X", .kind = .{ .config = &offset_x_config }, .font = .medium },
    .{ .label = "Offset Y", .kind = .{ .config = &offset_y_config }, .font = .medium },
    .{ .label = "Colour 1 Hue", .kind = .{ .config = &c1_h_config }, .font = .medium },
    .{ .label = "Colour 1 Sat", .kind = .{ .config = &c1_s_config }, .font = .medium },
    .{ .label = "Colour 1 Val", .kind = .{ .config = &c1_v_config }, .font = .medium },
    .{ .label = "Colour 2 Hue", .kind = .{ .config = &c2_h_config }, .font = .medium },
    .{ .label = "Colour 2 Sat", .kind = .{ .config = &c2_s_config }, .font = .medium },
    .{ .label = "Colour 2 Val", .kind = .{ .config = &c2_v_config }, .font = .medium },
    .{ .label = "Colour 3 Hue", .kind = .{ .config = &c3_h_config }, .font = .medium },
    .{ .label = "Colour 3 Sat", .kind = .{ .config = &c3_s_config }, .font = .medium },
    .{ .label = "Colour 3 Val", .kind = .{ .config = &c3_v_config }, .font = .medium },
    .{ .label = "Swirl: Paint Mix", .kind = .{ .button = actionCycleSwirl }, .font = .medium },
    .{ .label = "Noise: Sine Turbulence", .kind = .{ .button = actionCycleNoise }, .font = .medium },
    .{ .label = "Color: Distance Blend", .kind = .{ .button = actionCycleColorMode }, .font = .medium },
    .{ .label = "Randomize", .kind = .{ .button = actionRandomize }, .font = .medium },
    .{ .label = "Randomize All", .kind = .{ .button = actionRandomizeAll }, .font = .medium },
    .{ .label = "Save Preset", .kind = .{ .button = actionSavePreset }, .font = .medium },
    .{ .label = "Exit Editor", .kind = .{ .button = actionExitEditor }, .font = .medium },
};

pub fn open() void {
    loadFromUniforms();
    menu.open(&items, .{ .minimal_edit = true });
}

pub fn sync() void {
    background_paint.uniforms.spin_rotation = spin_rotation_config.value;
    background_paint.uniforms.spin_speed = spin_speed_config.value;
    background_paint.uniforms.contrast = contrast_config.value;
    background_paint.uniforms.spin_amount = spin_amount_config.value;
    background_paint.uniforms.pixel_filter = pixel_filter_config.value;
    background_paint.uniforms.offset = .{ offset_x_config.value, offset_y_config.value };

    background_paint.uniforms.colour_1 = background_paint.hsvToRgb(c1_h_config.value, c1_s_config.value, c1_v_config.value);
    background_paint.uniforms.colour_2 = background_paint.hsvToRgb(c2_h_config.value, c2_s_config.value, c2_v_config.value);
    background_paint.uniforms.colour_3 = background_paint.hsvToRgb(c3_h_config.value, c3_s_config.value, c3_v_config.value);

    background_paint.uniforms.swirl_type = @floatFromInt(swirl_type_value);
    background_paint.uniforms.noise_type = @floatFromInt(noise_type_value);
    background_paint.uniforms.color_mode = @floatFromInt(color_mode_value);
}

fn loadFromUniforms() void {
    const u = background_paint.uniforms;
    spin_rotation_config.value = u.spin_rotation;
    spin_speed_config.value = u.spin_speed;
    contrast_config.value = u.contrast;
    spin_amount_config.value = u.spin_amount;
    pixel_filter_config.value = u.pixel_filter;
    offset_x_config.value = u.offset[0];
    offset_y_config.value = u.offset[1];

    loadHsvFromRgb(u.colour_1, &c1_h_config, &c1_s_config, &c1_v_config);
    loadHsvFromRgb(u.colour_2, &c2_h_config, &c2_s_config, &c2_v_config);
    loadHsvFromRgb(u.colour_3, &c3_h_config, &c3_s_config, &c3_v_config);

    swirl_type_value = @intFromFloat(u.swirl_type);
    noise_type_value = @intFromFloat(u.noise_type);
    color_mode_value = @intFromFloat(u.color_mode);
    updateAlgorithmLabels();
}

fn loadHsvFromRgb(rgb: [3]f32, h_cfg: *menu.ConfigData, s_cfg: *menu.ConfigData, v_cfg: *menu.ConfigData) void {
    const hsv = background_paint.rgbToHsv(rgb);
    h_cfg.value = hsv[0];
    s_cfg.value = hsv[1];
    v_cfg.value = hsv[2];
}

fn updateAlgorithmLabels() void {
    items[17].label = swirl_names[swirl_type_value];
    items[18].label = noise_names[noise_type_value];
    items[19].label = color_names[color_mode_value];
}

fn actionBack() anyerror!void {
    menu.close();
}

fn actionCycleSwirl() anyerror!void {
    swirl_type_value = (swirl_type_value + 1) % SWIRL_COUNT;
    updateAlgorithmLabels();
    sync();
}

fn actionCycleNoise() anyerror!void {
    noise_type_value = (noise_type_value + 1) % NOISE_COUNT;
    updateAlgorithmLabels();
    sync();
}

fn actionCycleColorMode() anyerror!void {
    color_mode_value = (color_mode_value + 1) % COLOR_COUNT;
    updateAlgorithmLabels();
    sync();
}

fn actionRandomize() anyerror!void {
    background_paint.randomize();
    loadFromUniforms();
}

fn actionRandomizeAll() anyerror!void {
    const rng = std.crypto.random;
    background_paint.randomize();
    background_paint.uniforms.swirl_type = @floatFromInt(rng.intRangeAtMost(u8, 0, SWIRL_COUNT - 1));
    background_paint.uniforms.noise_type = @floatFromInt(rng.intRangeAtMost(u8, 0, NOISE_COUNT - 1));
    background_paint.uniforms.color_mode = @floatFromInt(rng.intRangeAtMost(u8, 0, COLOR_COUNT - 1));
    loadFromUniforms();
}

fn actionSavePreset() anyerror!void {
    sync();
    try settings.saveBackgroundPreset(background_paint.uniforms);
}

fn actionExitEditor() anyerror!void {
    state.editingBackground = false;
    menu.close();
}
