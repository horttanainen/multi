const std = @import("std");
const background_paint = @import("background_paint.zig");
const menu = @import("menu.zig");
const settings = @import("settings.zig");
const state = @import("state.zig");

// --- ConfigData for each tweakable parameter ---
// All 0.0–1.0 user-facing. shader_value = shader_offset + value * shader_scale.
// zig fmt: off
var spin_rotation_config = menu.ConfigData{ .value = 0,    .step = 0.01, .min = 0, .max = 1.0, .shader_offset = 0.0,  .shader_scale = 6.28,  .repeat_delay_ms = 75 };
var spin_speed_config    = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.1,  .rand_max = 0.8,  .shader_offset = 0.0,  .shader_scale = 0.1,   .repeat_delay_ms = 75 };
var contrast_config      = menu.ConfigData{ .value = 0.33, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.2,  .rand_max = 0.7,  .shader_offset = 0.5,  .shader_scale = 4.5,   .repeat_delay_ms = 75 };
var spin_amount_config   = menu.ConfigData{ .value = 0.4,  .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.2,  .rand_max = 0.8,  .shader_offset = 0.0,  .shader_scale = 1.0,   .repeat_delay_ms = 75 };
var pixel_filter_config  = menu.ConfigData{ .value = 0.27, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.13, .rand_max = 1.0, .shader_offset = 50.0, .shader_scale = 750.0, .repeat_delay_ms = 75 };
var offset_x_config      = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.35, .rand_max = 0.65, .shader_offset = -0.5, .shader_scale = 1.0,   .repeat_delay_ms = 75 };
var offset_y_config      = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.35, .rand_max = 0.65, .shader_offset = -0.5, .shader_scale = 1.0,   .repeat_delay_ms = 75 };
var offset_z_config      = menu.ConfigData{ .value = 0.18, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.2, .rand_max = 1.0,  .shader_offset = 0.1,  .shader_scale = 4.9,   .repeat_delay_ms = 75 };

// Shared controls
var noise_scale_config     = menu.ConfigData{ .value = 0.23, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.05, .rand_max = 0.6,  .shader_offset = 0.1, .shader_scale = 3.9, .repeat_delay_ms = 75 };
var noise_octaves_config   = menu.ConfigData{ .value = 5.0,  .step = 1.0,  .min = 1.0, .max = 16.0, .rand_min = 2.0, .rand_max = 10.0, .repeat_delay_ms = 150 };
var noise_speed_config     = menu.ConfigData{ .value = 0.25, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.05, .rand_max = 0.5,  .shader_offset = 0.0, .shader_scale = 2.0, .repeat_delay_ms = 75 };
var noise_amplitude_config = menu.ConfigData{ .value = 0.33, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.15, .rand_max = 0.6,  .shader_offset = 0.0, .shader_scale = 3.0, .repeat_delay_ms = 75 };
var color_intensity_config = menu.ConfigData{ .value = 0.31, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.2,  .rand_max = 0.4, .shader_offset = 0.1, .shader_scale = 2.9, .repeat_delay_ms = 75 };
var color_speed_config     = menu.ConfigData{ .value = 0.0,  .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.0,  .rand_max = 0.25, .shader_offset = 0.0, .shader_scale = 2.0, .repeat_delay_ms = 75 };
var swirl_falloff_config   = menu.ConfigData{ .value = 1.0,  .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.18, .rand_max = 0.8,  .shader_offset = 0.1, .shader_scale = 4.9, .repeat_delay_ms = 75 };
var swirl_segments_config  = menu.ConfigData{ .value = 6.0,  .step = 1.0,  .min = 2.0, .max = 16.0, .rand_min = 3.0, .rand_max = 10.0, .repeat_delay_ms = 150 };
var swirl_count_config     = menu.ConfigData{ .value = 1.0,  .step = 1.0,  .min = 1.0, .max = 4.0,  .rand_min = 1.0, .rand_max = 3.0,  .repeat_delay_ms = 200 };
var swirl_c1_x_config = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.2, .rand_max = 0.8, .shader_offset = -0.5, .shader_scale = 1.0, .repeat_delay_ms = 75 };
var swirl_c1_y_config = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.2, .rand_max = 0.8, .shader_offset = -0.5, .shader_scale = 1.0, .repeat_delay_ms = 75 };
var swirl_c2_x_config = menu.ConfigData{ .value = 0.75, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.2, .rand_max = 0.8, .shader_offset = -0.5, .shader_scale = 1.0, .repeat_delay_ms = 75 };
var swirl_c2_y_config = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.2, .rand_max = 0.8, .shader_offset = -0.5, .shader_scale = 1.0, .repeat_delay_ms = 75 };
var swirl_c3_x_config = menu.ConfigData{ .value = 0.25, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.2, .rand_max = 0.8, .shader_offset = -0.5, .shader_scale = 1.0, .repeat_delay_ms = 75 };
var swirl_c3_y_config = menu.ConfigData{ .value = 0.7,  .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.2, .rand_max = 0.8, .shader_offset = -0.5, .shader_scale = 1.0, .repeat_delay_ms = 75 };
var swirl_c4_x_config = menu.ConfigData{ .value = 0.5,  .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.2, .rand_max = 0.8, .shader_offset = -0.5, .shader_scale = 1.0, .repeat_delay_ms = 75 };
var swirl_c4_y_config = menu.ConfigData{ .value = 0.25, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.2, .rand_max = 0.8, .shader_offset = -0.5, .shader_scale = 1.0, .repeat_delay_ms = 75 };
// zig fmt: on

// HSV controls for 3 colours (already 0–1 naturally)
var c1_h_config = menu.ConfigData{ .value = 0, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var c1_s_config = menu.ConfigData{ .value = 0.7, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.55, .rand_max = 0.85, .repeat_delay_ms = 75 };
var c1_v_config = menu.ConfigData{ .value = 0.6, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.40, .rand_max = 0.75, .repeat_delay_ms = 75 };
var c2_h_config = menu.ConfigData{ .value = 0, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var c2_s_config = menu.ConfigData{ .value = 0.7, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.55, .rand_max = 0.85, .repeat_delay_ms = 75 };
var c2_v_config = menu.ConfigData{ .value = 0.6, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.40, .rand_max = 0.75, .repeat_delay_ms = 75 };
var c3_h_config = menu.ConfigData{ .value = 0, .step = 0.01, .min = 0, .max = 1.0, .repeat_delay_ms = 75 };
var c3_s_config = menu.ConfigData{ .value = 0.7, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.45, .rand_max = 0.75, .repeat_delay_ms = 75 };
var c3_v_config = menu.ConfigData{ .value = 0.6, .step = 0.01, .min = 0, .max = 1.0, .rand_min = 0.45, .rand_max = 0.85, .repeat_delay_ms = 75 };

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
    .{ .label = "Swirl Falloff", .kind = .{ .config = &swirl_falloff_config }, .font = .medium },
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
    .{ .label = "Noise Speed", .kind = .{ .config = &noise_speed_config }, .font = .medium },
    .{ .label = "Noise Amplitude", .kind = .{ .config = &noise_amplitude_config }, .font = .medium },
    .{ .label = "Noise Octaves", .kind = .{ .config = &noise_octaves_config }, .font = .medium },
};

var color_items = [_]menu.Item{
    .{ .label = "Back", .kind = .{ .button = actionBackToMain }, .font = .medium },
    .{ .label = "Color Intensity", .kind = .{ .config = &color_intensity_config }, .font = .medium },
    .{ .label = "Color Speed", .kind = .{ .config = &color_speed_config }, .font = .medium },
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
    background_paint.uniforms.spin_rotation = toShader(&spin_rotation_config);
    background_paint.uniforms.spin_speed = toShader(&spin_speed_config);
    background_paint.uniforms.contrast = toShader(&contrast_config);
    background_paint.uniforms.spin_amount = toShader(&spin_amount_config);
    background_paint.uniforms.pixel_filter = toShader(&pixel_filter_config);
    background_paint.uniforms.offset = .{ toShader(&offset_x_config), toShader(&offset_y_config) };

    background_paint.uniforms.offset_z = toShader(&offset_z_config);
    background_paint.uniforms.noise_scale = toShader(&noise_scale_config);
    background_paint.uniforms.noise_speed = toShader(&noise_speed_config);
    background_paint.uniforms.noise_amplitude = toShader(&noise_amplitude_config);
    background_paint.uniforms.noise_octaves = noise_octaves_config.value;
    background_paint.uniforms.color_intensity = toShader(&color_intensity_config);
    background_paint.uniforms.color_speed = toShader(&color_speed_config);
    background_paint.uniforms.swirl_falloff = toShader(&swirl_falloff_config);
    background_paint.uniforms.swirl_segments = swirl_segments_config.value;
    background_paint.uniforms.swirl_count = swirl_count_config.value;
    background_paint.uniforms.swirl_center_1 = .{ toShader(&swirl_c1_x_config), toShader(&swirl_c1_y_config) };
    background_paint.uniforms.swirl_center_2 = .{ toShader(&swirl_c2_x_config), toShader(&swirl_c2_y_config) };
    background_paint.uniforms.swirl_center_3 = .{ toShader(&swirl_c3_x_config), toShader(&swirl_c3_y_config) };
    background_paint.uniforms.swirl_center_4 = .{ toShader(&swirl_c4_x_config), toShader(&swirl_c4_y_config) };

    background_paint.uniforms.colour_1 = hsvToRgb(c1_h_config.value, c1_s_config.value, c1_v_config.value);
    background_paint.uniforms.colour_2 = hsvToRgb(c2_h_config.value, c2_s_config.value, c2_v_config.value);
    background_paint.uniforms.colour_3 = hsvToRgb(c3_h_config.value, c3_s_config.value, c3_v_config.value);

    background_paint.uniforms.swirl_type = @floatFromInt(swirl_type_value);
    background_paint.uniforms.noise_type = @floatFromInt(noise_type_value);
    background_paint.uniforms.color_mode = @floatFromInt(color_mode_value);
}

// ============================================================
// Internal helpers
// ============================================================

fn loadFromUniforms() void {
    const u = background_paint.uniforms;
    fromShader(&spin_rotation_config, u.spin_rotation);
    fromShader(&spin_speed_config, u.spin_speed);
    fromShader(&contrast_config, u.contrast);
    fromShader(&spin_amount_config, u.spin_amount);
    fromShader(&pixel_filter_config, u.pixel_filter);
    fromShader(&offset_x_config, u.offset[0]);
    fromShader(&offset_y_config, u.offset[1]);

    fromShader(&offset_z_config, u.offset_z);
    fromShader(&noise_scale_config, u.noise_scale);
    fromShader(&noise_speed_config, u.noise_speed);
    fromShader(&noise_amplitude_config, u.noise_amplitude);
    noise_octaves_config.value = u.noise_octaves;
    fromShader(&color_intensity_config, u.color_intensity);
    fromShader(&color_speed_config, u.color_speed);
    fromShader(&swirl_falloff_config, u.swirl_falloff);
    swirl_segments_config.value = u.swirl_segments;
    swirl_count_config.value = u.swirl_count;
    fromShader(&swirl_c1_x_config, u.swirl_center_1[0]);
    fromShader(&swirl_c1_y_config, u.swirl_center_1[1]);
    fromShader(&swirl_c2_x_config, u.swirl_center_2[0]);
    fromShader(&swirl_c2_y_config, u.swirl_center_2[1]);
    fromShader(&swirl_c3_x_config, u.swirl_center_3[0]);
    fromShader(&swirl_c3_y_config, u.swirl_center_3[1]);
    fromShader(&swirl_c4_x_config, u.swirl_center_4[0]);
    fromShader(&swirl_c4_y_config, u.swirl_center_4[1]);

    loadHsvFromRgb(u.colour_1, &c1_h_config, &c1_s_config, &c1_v_config);
    loadHsvFromRgb(u.colour_2, &c2_h_config, &c2_s_config, &c2_v_config);
    loadHsvFromRgb(u.colour_3, &c3_h_config, &c3_s_config, &c3_v_config);

    swirl_type_value = @intFromFloat(u.swirl_type);
    noise_type_value = @intFromFloat(u.noise_type);
    color_mode_value = @intFromFloat(u.color_mode);
    updateAlgorithmLabels();
}

fn loadHsvFromRgb(rgb: [3]f32, h_cfg: *menu.ConfigData, s_cfg: *menu.ConfigData, v_cfg: *menu.ConfigData) void {
    const hsv = rgbToHsv(rgb);
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

fn randomizeSwirl() void {
    spin_rotation_config.value = randomInRange(spin_rotation_config);
    spin_speed_config.value = randomInRange(spin_speed_config);
    spin_amount_config.value = randomInRange(spin_amount_config);
    swirl_falloff_config.value = randomInRange(swirl_falloff_config);
    swirl_segments_config.value = randomIntInRange(swirl_segments_config);
    swirl_count_config.value = randomIntInRange(swirl_count_config);
    swirl_c1_x_config.value = randomInRange(swirl_c1_x_config);
    swirl_c1_y_config.value = randomInRange(swirl_c1_y_config);
    swirl_c2_x_config.value = randomInRange(swirl_c2_x_config);
    swirl_c2_y_config.value = randomInRange(swirl_c2_y_config);
    swirl_c3_x_config.value = randomInRange(swirl_c3_x_config);
    swirl_c3_y_config.value = randomInRange(swirl_c3_y_config);
    swirl_c4_x_config.value = randomInRange(swirl_c4_x_config);
    swirl_c4_y_config.value = randomInRange(swirl_c4_y_config);
}

fn randomizeNoise() void {
    noise_scale_config.value = randomInRange(noise_scale_config);
    noise_speed_config.value = randomInRange(noise_speed_config);
    noise_amplitude_config.value = randomInRange(noise_amplitude_config);
    noise_octaves_config.value = randomIntInRange(noise_octaves_config);
}

fn randomizeColors() void {
    const rng = std.crypto.random;
    const base_hue: f32 = rng.float(f32);
    const hue_step: f32 = 0.08 + rng.float(f32) * 0.15;
    c1_h_config.value = base_hue;
    c1_s_config.value = randomInRange(c1_s_config);
    c1_v_config.value = randomInRange(c1_v_config);
    c2_h_config.value = @mod(base_hue + hue_step, 1.0);
    c2_s_config.value = randomInRange(c2_s_config);
    c2_v_config.value = randomInRange(c2_v_config);
    c3_h_config.value = @mod(base_hue + 0.45 + rng.float(f32) * 0.15, 1.0);
    c3_s_config.value = randomInRange(c3_s_config);
    c3_v_config.value = randomInRange(c3_v_config);
    color_intensity_config.value = randomInRange(color_intensity_config);
    color_speed_config.value = randomInRange(color_speed_config);
    contrast_config.value = randomInRange(contrast_config);
}

fn randomizeGlobal() void {
    offset_x_config.value = randomInRange(offset_x_config);
    offset_y_config.value = randomInRange(offset_y_config);
    offset_z_config.value = randomInRange(offset_z_config);
    pixel_filter_config.value = randomInRange(pixel_filter_config);
}

/// Randomize all parameters (preserving algorithm selections).
pub fn randomize() void {
    randomizeSwirl();
    randomizeNoise();
    randomizeColors();
    randomizeGlobal();
    sync();
    std.log.info("background_paint: randomized (pixel_filter={d:.0})", .{background_paint.uniforms.pixel_filter});
}

fn randomizeAlgorithms() void {
    const rng = std.crypto.random;
    swirl_type_value = rng.intRangeAtMost(u8, 0, SWIRL_COUNT - 1);
    noise_type_value = rng.intRangeAtMost(u8, 0, NOISE_COUNT - 1);
    color_mode_value = rng.intRangeAtMost(u8, 0, COLOR_COUNT - 1);
    updateAlgorithmLabels();
}

fn toShader(cfg: *const menu.ConfigData) f32 {
    return cfg.shader_offset + cfg.value * cfg.shader_scale;
}

fn fromShader(cfg: *menu.ConfigData, shader: f32) void {
    cfg.value = std.math.clamp((shader - cfg.shader_offset) / cfg.shader_scale, 0.0, 1.0);
}

fn randomInRange(cfg: menu.ConfigData) f32 {
    const rng = std.crypto.random;
    const lo = cfg.rand_min orelse cfg.min;
    const hi = cfg.rand_max orelse cfg.max;
    return lo + rng.float(f32) * (hi - lo);
}

fn randomIntInRange(cfg: menu.ConfigData) f32 {
    const rng = std.crypto.random;
    const lo: u8 = @intFromFloat(cfg.rand_min orelse cfg.min);
    const hi: u8 = @intFromFloat(cfg.rand_max orelse cfg.max);
    return @floatFromInt(rng.intRangeAtMost(u8, lo, hi));
}

fn actionRandomizeSwirl() anyerror!void {
    randomizeSwirl();
    sync();
}

fn actionRandomizeNoise() anyerror!void {
    randomizeNoise();
    sync();
}

fn actionRandomizeColors() anyerror!void {
    randomizeColors();
    sync();
}

fn actionRandomize() anyerror!void {
    randomize();
}

fn actionRandomizeAll() anyerror!void {
    randomizeAlgorithms();
    randomize();
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

pub fn hsvToRgb(h: f32, s: f32, v: f32) [3]f32 {
    const i: u32 = @intFromFloat(@mod(@floor(h * 6.0), 6.0));
    const f: f32 = h * 6.0 - @floor(h * 6.0);
    const p: f32 = v * (1.0 - s);
    const q: f32 = v * (1.0 - f * s);
    const t: f32 = v * (1.0 - (1.0 - f) * s);
    return switch (i) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
}

pub fn rgbToHsv(rgb: [3]f32) [3]f32 {
    const r = rgb[0];
    const g = rgb[1];
    const b = rgb[2];
    const max_c = @max(r, @max(g, b));
    const min_c = @min(r, @min(g, b));
    const delta = max_c - min_c;

    var h: f32 = 0;
    if (delta > 0.00001) {
        if (max_c == r) {
            h = @mod((g - b) / delta, 6.0) / 6.0;
        } else if (max_c == g) {
            h = ((b - r) / delta + 2.0) / 6.0;
        } else {
            h = ((r - g) / delta + 4.0) / 6.0;
        }
        if (h < 0) h += 1.0;
    }

    const s: f32 = if (max_c > 0.00001) delta / max_c else 0;
    return .{ h, s, max_c };
}
