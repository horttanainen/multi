const std = @import("std");
const background_paint = @import("background_paint.zig");
const menu = @import("menu.zig");
const settings = @import("settings.zig");
const state = @import("state.zig");

// --- ConfigData for each tweakable parameter ---
var spin_rotation_config = menu.ConfigData{ .value = 0, .step = 0.1, .min = 0, .max = 6.28, .repeat_delay_ms = 75 };
var spin_speed_config = menu.ConfigData{ .value = 0.5, .step = 0.01, .min = 0, .max = 2.0, .repeat_delay_ms = 75 };
var contrast_config = menu.ConfigData{ .value = 2.0, .step = 0.1, .min = 0.5, .max = 5.0, .repeat_delay_ms = 75 };
var spin_amount_config = menu.ConfigData{ .value = 0.4, .step = 0.02, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var pixel_filter_config = menu.ConfigData{ .value = 250, .step = 10, .min = 50, .max = 800, .repeat_delay_ms = 75 };
var offset_x_config = menu.ConfigData{ .value = 0, .step = 0.01, .min = -0.5, .max = 0.5, .repeat_delay_ms = 75 };
var offset_y_config = menu.ConfigData{ .value = 0, .step = 0.01, .min = -0.5, .max = 0.5, .repeat_delay_ms = 75 };
var offset_z_config = menu.ConfigData{ .value = 1.0, .step = 0.05, .min = 0.1, .max = 5.0, .repeat_delay_ms = 75 };

// Shared controls
var noise_scale_config = menu.ConfigData{ .value = 1.0, .step = 0.05, .min = 0.1, .max = 4.0, .repeat_delay_ms = 75 };
var noise_octaves_config = menu.ConfigData{ .value = 5.0, .step = 1.0, .min = 1.0, .max = 16.0, .repeat_delay_ms = 150 };
var color_intensity_config = menu.ConfigData{ .value = 1.0, .step = 0.05, .min = 0.1, .max = 3.0, .repeat_delay_ms = 75 };
var swirl_segments_config = menu.ConfigData{ .value = 6.0, .step = 1.0, .min = 2.0, .max = 16.0, .repeat_delay_ms = 150 };
var swirl_count_config = menu.ConfigData{ .value = 1.0, .step = 1.0, .min = 1.0, .max = 4.0, .repeat_delay_ms = 200 };
var swirl_c1_x_config = menu.ConfigData{ .value = 0.0, .step = 0.01, .min = -0.5, .max = 0.5, .repeat_delay_ms = 75 };
var swirl_c1_y_config = menu.ConfigData{ .value = 0.0, .step = 0.01, .min = -0.5, .max = 0.5, .repeat_delay_ms = 75 };
var swirl_c2_x_config = menu.ConfigData{ .value = 0.25, .step = 0.01, .min = -0.5, .max = 0.5, .repeat_delay_ms = 75 };
var swirl_c2_y_config = menu.ConfigData{ .value = 0.0, .step = 0.01, .min = -0.5, .max = 0.5, .repeat_delay_ms = 75 };
var swirl_c3_x_config = menu.ConfigData{ .value = -0.25, .step = 0.01, .min = -0.5, .max = 0.5, .repeat_delay_ms = 75 };
var swirl_c3_y_config = menu.ConfigData{ .value = 0.2, .step = 0.01, .min = -0.5, .max = 0.5, .repeat_delay_ms = 75 };
var swirl_c4_x_config = menu.ConfigData{ .value = 0.0, .step = 0.01, .min = -0.5, .max = 0.5, .repeat_delay_ms = 75 };
var swirl_c4_y_config = menu.ConfigData{ .value = -0.25, .step = 0.01, .min = -0.5, .max = 0.5, .repeat_delay_ms = 75 };

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

// ============================================================
// Top-level menu
// ============================================================

const IDX_MAIN_SWIRL: usize = 1;
const IDX_MAIN_NOISE: usize = 4;
const IDX_MAIN_COLOR: usize = 7;

var main_items = [_]menu.Item{
    .{ .label = "Exit Editor", .kind = .{ .button = actionExitEditor }, .font = .medium },
    // --- Swirl ---
    .{ .label = "Swirl: Paint Mix", .kind = .{ .button = actionCycleSwirl }, .font = .medium, .cycle_names = &swirl_names, .cycle_index = &swirl_type_value, .on_cycle = onCycleSync },
    .{ .label = "Tweak Swirl", .kind = .{ .button = actionOpenSwirlMenu }, .font = .medium },
    .{ .label = "Randomize Swirl", .kind = .{ .button = actionRandomizeSwirl }, .font = .medium },
    // --- Noise ---
    .{ .label = "Noise: Sine Turbulence", .kind = .{ .button = actionCycleNoise }, .font = .medium, .cycle_names = &noise_names, .cycle_index = &noise_type_value, .on_cycle = onCycleSync },
    .{ .label = "Tweak Noise", .kind = .{ .button = actionOpenNoiseMenu }, .font = .medium },
    .{ .label = "Randomize Noise", .kind = .{ .button = actionRandomizeNoise }, .font = .medium },
    // --- Color ---
    .{ .label = "Color: Distance Blend", .kind = .{ .button = actionCycleColorMode }, .font = .medium, .cycle_names = &color_names, .cycle_index = &color_mode_value, .on_cycle = onCycleSync },
    .{ .label = "Tweak Colors", .kind = .{ .button = actionOpenColorMenu }, .font = .medium },
    .{ .label = "Randomize Colors", .kind = .{ .button = actionRandomizeColors }, .font = .medium },
    // --- Global ---
    .{ .label = "Tweak Global", .kind = .{ .button = actionOpenGlobalMenu }, .font = .medium },
    .{ .label = "Randomize", .kind = .{ .button = actionRandomize }, .font = .medium },
    .{ .label = "Randomize All", .kind = .{ .button = actionRandomizeAll }, .font = .medium },
    .{ .label = "Save Preset", .kind = .{ .button = actionSavePreset }, .font = .medium },
};

// ============================================================
// Sub-menus
// ============================================================

var swirl_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Spin Rotation", .kind = .{ .config = &spin_rotation_config }, .font = .medium },
    .{ .label = "Spin Speed", .kind = .{ .config = &spin_speed_config }, .font = .medium },
    .{ .label = "Spin Amount", .kind = .{ .config = &spin_amount_config }, .font = .medium },
    .{ .label = "Swirl Segments", .kind = .{ .config = &swirl_segments_config }, .font = .medium },
    .{ .label = "Swirl Centers", .kind = .{ .config = &swirl_count_config }, .font = .medium },
    .{ .label = "Center 1 X", .kind = .{ .config = &swirl_c1_x_config }, .font = .medium },
    .{ .label = "Center 1 Y", .kind = .{ .config = &swirl_c1_y_config }, .font = .medium },
    .{ .label = "Center 2 X", .kind = .{ .config = &swirl_c2_x_config }, .font = .medium },
    .{ .label = "Center 2 Y", .kind = .{ .config = &swirl_c2_y_config }, .font = .medium },
    .{ .label = "Center 3 X", .kind = .{ .config = &swirl_c3_x_config }, .font = .medium },
    .{ .label = "Center 3 Y", .kind = .{ .config = &swirl_c3_y_config }, .font = .medium },
    .{ .label = "Center 4 X", .kind = .{ .config = &swirl_c4_x_config }, .font = .medium },
    .{ .label = "Center 4 Y", .kind = .{ .config = &swirl_c4_y_config }, .font = .medium },
};

var noise_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Noise Scale", .kind = .{ .config = &noise_scale_config }, .font = .medium },
    .{ .label = "Noise Octaves", .kind = .{ .config = &noise_octaves_config }, .font = .medium },
};

var color_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Color Intensity", .kind = .{ .config = &color_intensity_config }, .font = .medium },
    .{ .label = "Contrast", .kind = .{ .config = &contrast_config }, .font = .medium },
    .{ .label = "Colour 1 Hue", .kind = .{ .config = &c1_h_config }, .font = .medium },
    .{ .label = "Colour 1 Sat", .kind = .{ .config = &c1_s_config }, .font = .medium },
    .{ .label = "Colour 1 Val", .kind = .{ .config = &c1_v_config }, .font = .medium },
    .{ .label = "Colour 2 Hue", .kind = .{ .config = &c2_h_config }, .font = .medium },
    .{ .label = "Colour 2 Sat", .kind = .{ .config = &c2_s_config }, .font = .medium },
    .{ .label = "Colour 2 Val", .kind = .{ .config = &c2_v_config }, .font = .medium },
    .{ .label = "Colour 3 Hue", .kind = .{ .config = &c3_h_config }, .font = .medium },
    .{ .label = "Colour 3 Sat", .kind = .{ .config = &c3_s_config }, .font = .medium },
    .{ .label = "Colour 3 Val", .kind = .{ .config = &c3_v_config }, .font = .medium },
};

var global_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Offset X", .kind = .{ .config = &offset_x_config }, .font = .medium },
    .{ .label = "Offset Y", .kind = .{ .config = &offset_y_config }, .font = .medium },
    .{ .label = "Zoom", .kind = .{ .config = &offset_z_config }, .font = .medium },
    .{ .label = "Pixel Filter", .kind = .{ .config = &pixel_filter_config }, .font = .medium },
};

// ============================================================
// Public API
// ============================================================

pub fn open() void {
    loadFromUniforms();
    menu.open(&main_items, .{ .minimal_edit = true });
}

pub fn sync() void {
    background_paint.uniforms.spin_rotation = spin_rotation_config.value;
    background_paint.uniforms.spin_speed = spin_speed_config.value;
    background_paint.uniforms.contrast = contrast_config.value;
    background_paint.uniforms.spin_amount = spin_amount_config.value;
    background_paint.uniforms.pixel_filter = pixel_filter_config.value;
    background_paint.uniforms.offset = .{ offset_x_config.value, offset_y_config.value };

    background_paint.uniforms.offset_z = offset_z_config.value;
    background_paint.uniforms.noise_scale = noise_scale_config.value;
    background_paint.uniforms.noise_octaves = noise_octaves_config.value;
    background_paint.uniforms.color_intensity = color_intensity_config.value;
    background_paint.uniforms.swirl_segments = swirl_segments_config.value;
    background_paint.uniforms.swirl_count = swirl_count_config.value;
    background_paint.uniforms.swirl_center_1 = .{ swirl_c1_x_config.value, swirl_c1_y_config.value };
    background_paint.uniforms.swirl_center_2 = .{ swirl_c2_x_config.value, swirl_c2_y_config.value };
    background_paint.uniforms.swirl_center_3 = .{ swirl_c3_x_config.value, swirl_c3_y_config.value };
    background_paint.uniforms.swirl_center_4 = .{ swirl_c4_x_config.value, swirl_c4_y_config.value };

    background_paint.uniforms.colour_1 = background_paint.hsvToRgb(c1_h_config.value, c1_s_config.value, c1_v_config.value);
    background_paint.uniforms.colour_2 = background_paint.hsvToRgb(c2_h_config.value, c2_s_config.value, c2_v_config.value);
    background_paint.uniforms.colour_3 = background_paint.hsvToRgb(c3_h_config.value, c3_s_config.value, c3_v_config.value);

    background_paint.uniforms.swirl_type = @floatFromInt(swirl_type_value);
    background_paint.uniforms.noise_type = @floatFromInt(noise_type_value);
    background_paint.uniforms.color_mode = @floatFromInt(color_mode_value);
}

// ============================================================
// Internal helpers
// ============================================================

fn loadFromUniforms() void {
    const u = background_paint.uniforms;
    spin_rotation_config.value = u.spin_rotation;
    spin_speed_config.value = u.spin_speed;
    contrast_config.value = u.contrast;
    spin_amount_config.value = u.spin_amount;
    pixel_filter_config.value = u.pixel_filter;
    offset_x_config.value = u.offset[0];
    offset_y_config.value = u.offset[1];

    offset_z_config.value = u.offset_z;
    noise_scale_config.value = u.noise_scale;
    noise_octaves_config.value = u.noise_octaves;
    color_intensity_config.value = u.color_intensity;
    swirl_segments_config.value = u.swirl_segments;
    swirl_count_config.value = u.swirl_count;
    swirl_c1_x_config.value = u.swirl_center_1[0];
    swirl_c1_y_config.value = u.swirl_center_1[1];
    swirl_c2_x_config.value = u.swirl_center_2[0];
    swirl_c2_y_config.value = u.swirl_center_2[1];
    swirl_c3_x_config.value = u.swirl_center_3[0];
    swirl_c3_y_config.value = u.swirl_center_3[1];
    swirl_c4_x_config.value = u.swirl_center_4[0];
    swirl_c4_y_config.value = u.swirl_center_4[1];

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

fn onCycleSync() void {
    updateAlgorithmLabels();
    sync();
}

fn updateAlgorithmLabels() void {
    main_items[IDX_MAIN_SWIRL].label = swirl_names[swirl_type_value];
    main_items[IDX_MAIN_NOISE].label = noise_names[noise_type_value];
    main_items[IDX_MAIN_COLOR].label = color_names[color_mode_value];
}

// ============================================================
// Navigation actions
// ============================================================

fn actionBackToMain() anyerror!void {
    menu.open(&main_items, .{ .minimal_edit = true });
}

fn actionOpenSwirlMenu() anyerror!void {
    menu.open(&swirl_items, .{ .minimal_edit = true, .back_fn = actionBackToMain });
}

fn actionOpenNoiseMenu() anyerror!void {
    menu.open(&noise_items, .{ .minimal_edit = true, .back_fn = actionBackToMain });
}

fn actionOpenColorMenu() anyerror!void {
    menu.open(&color_items, .{ .minimal_edit = true, .back_fn = actionBackToMain });
}

fn actionOpenGlobalMenu() anyerror!void {
    menu.open(&global_items, .{ .minimal_edit = true, .back_fn = actionBackToMain });
}

// ============================================================
// Algorithm cycling actions
// ============================================================

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

// ============================================================
// Randomize actions
// ============================================================

fn actionRandomizeSwirl() anyerror!void {
    const rng = std.crypto.random;
    spin_rotation_config.value = rng.float(f32) * std.math.tau;
    spin_speed_config.value = 0.1 + rng.float(f32) * 1.5;
    spin_amount_config.value = rng.float(f32) * 0.8;
    swirl_segments_config.value = @floatFromInt(rng.intRangeAtMost(u8, 2, 12));
    sync();
}

fn actionRandomizeNoise() anyerror!void {
    const rng = std.crypto.random;
    noise_scale_config.value = 0.2 + rng.float(f32) * 3.0;
    noise_octaves_config.value = @floatFromInt(rng.intRangeAtMost(u8, 2, 10));
    sync();
}

fn actionRandomizeColors() anyerror!void {
    const rng = std.crypto.random;
    const base_hue: f32 = rng.float(f32);
    const hue_step: f32 = 0.08 + rng.float(f32) * 0.15;
    const sat: f32 = 0.55 + rng.float(f32) * 0.3;
    const val: f32 = 0.40 + rng.float(f32) * 0.35;
    c1_h_config.value = base_hue;
    c1_s_config.value = sat;
    c1_v_config.value = val;
    c2_h_config.value = @mod(base_hue + hue_step, 1.0);
    c2_s_config.value = sat;
    c2_v_config.value = val;
    c3_h_config.value = @mod(base_hue + 0.45 + rng.float(f32) * 0.15, 1.0);
    c3_s_config.value = sat * 0.85;
    c3_v_config.value = @min(val * 1.15, 1.0);
    color_intensity_config.value = 0.5 + rng.float(f32) * 1.5;
    contrast_config.value = 1.5 + rng.float(f32) * 1.5;
    sync();
}

fn actionRandomize() anyerror!void {
    const rng = std.crypto.random;
    background_paint.randomize();
    background_paint.uniforms.swirl_segments = @floatFromInt(rng.intRangeAtMost(u8, 2, 12));
    background_paint.uniforms.swirl_count = @floatFromInt(rng.intRangeAtMost(u8, 1, 4));
    background_paint.uniforms.offset_z = 0.3 + rng.float(f32) * 2.5;
    background_paint.uniforms.swirl_center_1 = .{ (rng.float(f32) - 0.5) * 0.6, (rng.float(f32) - 0.5) * 0.6 };
    background_paint.uniforms.swirl_center_2 = .{ (rng.float(f32) - 0.5) * 0.6, (rng.float(f32) - 0.5) * 0.6 };
    background_paint.uniforms.swirl_center_3 = .{ (rng.float(f32) - 0.5) * 0.6, (rng.float(f32) - 0.5) * 0.6 };
    background_paint.uniforms.swirl_center_4 = .{ (rng.float(f32) - 0.5) * 0.6, (rng.float(f32) - 0.5) * 0.6 };
    loadFromUniforms();
}

fn actionRandomizeAll() anyerror!void {
    const rng = std.crypto.random;
    background_paint.randomize();
    background_paint.uniforms.swirl_type = @floatFromInt(rng.intRangeAtMost(u8, 0, SWIRL_COUNT - 1));
    background_paint.uniforms.noise_type = @floatFromInt(rng.intRangeAtMost(u8, 0, NOISE_COUNT - 1));
    background_paint.uniforms.color_mode = @floatFromInt(rng.intRangeAtMost(u8, 0, COLOR_COUNT - 1));
    background_paint.uniforms.swirl_segments = @floatFromInt(rng.intRangeAtMost(u8, 2, 12));
    background_paint.uniforms.swirl_count = @floatFromInt(rng.intRangeAtMost(u8, 1, 4));
    background_paint.uniforms.offset_z = 0.3 + rng.float(f32) * 2.5;
    background_paint.uniforms.swirl_center_1 = .{ (rng.float(f32) - 0.5) * 0.6, (rng.float(f32) - 0.5) * 0.6 };
    background_paint.uniforms.swirl_center_2 = .{ (rng.float(f32) - 0.5) * 0.6, (rng.float(f32) - 0.5) * 0.6 };
    background_paint.uniforms.swirl_center_3 = .{ (rng.float(f32) - 0.5) * 0.6, (rng.float(f32) - 0.5) * 0.6 };
    background_paint.uniforms.swirl_center_4 = .{ (rng.float(f32) - 0.5) * 0.6, (rng.float(f32) - 0.5) * 0.6 };
    loadFromUniforms();
}

// ============================================================
// Persistence / exit
// ============================================================

fn actionSavePreset() anyerror!void {
    sync();
    try settings.saveBackgroundPreset(background_paint.uniforms);
}

fn actionExitEditor() anyerror!void {
    state.editingBackground = false;
    menu.close();
}
