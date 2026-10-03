const character_hair = @import("character_hair.zig");
const std = @import("std");
const animation = @import("character_animation.zig");
const data = @import("data.zig");
const sprite = @import("sprite.zig");
const player = @import("player.zig");
const entity = @import("entity.zig");
const vec = @import("vector.zig");
const conv = @import("conversion.zig");
const camera = @import("camera.zig");
const blood = @import("blood.zig");
const box2d = @import("box2d.zig");
const allocator = @import("allocator.zig").allocator;

const joint_count = std.meta.fields(animation.Joint).len;
const invalid = data.invalidCharacterAsset;
pub const Part = struct {
    definition: data.CharacterArtPart,
    paths: [2][]const u8,
    sprites: [2]?u64 = .{ null, null },
    gib_blood_path: ?[]const u8 = null,
    gib_blood_sprite: ?u64 = null,
};
pub const Binding = struct {
    part: usize,
    anchor: animation.Joint,
    axis: [2]animation.Joint,
    depth: data.CharacterArtDepth,
    survival_weight: f32,
    ragdoll: ?RagdollJoint = null,
};
pub const RagdollJoint = struct { parent: usize, reference_angle: f32, limits: [2]f32 };
pub const DrawItem = union(enum) { part: usize, weapon: data.CharacterArtDepth, holster };
pub const Image = struct {
    definition: data.CharacterArtImage,
    path: []const u8,
    sprite_id: ?u64 = null,
};
pub const Knife = struct {
    definition: data.CharacterKnife,
    image: Image,
    buried: Image,
    horizontal: Image,
};
pub const Hair = struct {
    definition: data.CharacterHairData,
    head_binding: usize,
    scalp: Image,
    lock: Image,
    players: std.AutoHashMapUnmanaged(usize, data.CharacterHairAppearance),
};
pub const ImagePlacement = struct {
    position: vec.Vec2,
    angle: f32,
    scale: vec.Vec2, // World meters per source pixel.
    facing_right: bool,
};
pub const HairFrame = struct { head: PlacedPart, appearance: data.CharacterHairAppearance };
pub const Pack = struct {
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    parts: []Part,
    bindings: []Binding,
    order: [2][]DrawItem,
    grip_part: usize,
    weapon_joint: animation.Joint,
    far_skin_multiplier: f32,
    hair: ?Hair = null,
    knife: ?Knife = null,
};
pub const PlacedPart = struct { part: usize, position: vec.Vec2, angle: f32, facing_right: bool, far: bool };
pub const DetachedPart = struct {
    part: usize,
    facing_right: bool,
    skin_color: sprite.Color,
    severed: bool = false,
    hair: ?data.CharacterHairAppearance = null,
};
pub var assets: ?Pack = null;
pub var bodyParts = std.AutoArrayHashMapUnmanaged(box2d.c.b2BodyId, DetachedPart).empty;

fn relativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 256 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, "..") or std.mem.eql(u8, component, ".")) return false;
    }
    return true;
}

fn point(value: [2]f32) vec.Vec2 {
    return .{ .x = value[0], .y = value[1] };
}

pub fn isFar(depth: data.CharacterArtDepth, facing_right: bool) bool {
    return depth == (if (facing_right) data.CharacterArtDepth.right else .left);
}

fn validatePart(name: []const u8, part: data.CharacterArtPart, detail: *data.CharacterAssetDiagnostic) !void {
    if (!std.math.isFinite(part.meters_per_pixel) or part.meters_per_pixel <= 0 or part.meters_per_pixel > 1) return invalid(detail, "parts.{s}: invalid meters_per_pixel", .{name});
    for (part.pivot ++ part.axis_end) |value| {
        if (!std.math.isFinite(value) or value < 0 or value > 10000) return invalid(detail, "parts.{s}: invalid pivot/axis coordinate", .{name});
    }
    if (vec.magnitude(vec.subtract(point(part.pivot), point(part.axis_end))) < 1) return invalid(detail, "parts.{s}: degenerate source axis", .{name});
    if (part.layers[0].role != .skin or part.layers[1].role != .fixed) return invalid(detail, "parts.{s}: layers must be skin then fixed", .{name});
    if (std.mem.eql(u8, part.layers[0].file, part.layers[1].file)) return invalid(detail, "parts.{s}: layers must use distinct files", .{name});
    for (part.layers) |layer| {
        if (!relativePath(layer.file)) return invalid(detail, "parts.{s}: invalid relative layer path", .{name});
    }
    for (part.physics.center) |value| {
        if (!std.math.isFinite(value) or value < 0 or value > 10000) {
            return invalid(detail, "parts.{s}.physics.center: invalid source coordinate", .{name});
        }
    }
    for (part.physics.half_extents) |value| {
        if (!std.math.isFinite(value) or value <= 0 or value > 10000) {
            return invalid(detail, "parts.{s}.physics.half_extents: expected positive source extent", .{name});
        }
    }
    const density = part.physics.density;
    if (!std.math.isFinite(density) or density <= 0 or density > 1000) {
        return invalid(detail, "parts.{s}.physics.density: expected 0..1000", .{name});
    }
    const friction = part.physics.friction;
    if (!std.math.isFinite(friction) or friction < 0 or friction > 1) {
        return invalid(detail, "parts.{s}.physics.friction: expected 0..1", .{name});
    }
    if (part.gib_blood == null) return; // Optional decoration, with no effect on physics.
    const path = part.gib_blood.?;
    if (!relativePath(path)) {
        return invalid(detail, "parts.{s}: invalid relative gib_blood path", .{name});
    }
    for (part.layers) |layer| {
        if (std.mem.eql(u8, path, layer.file)) {
            return invalid(detail, "parts.{s}: gib_blood must use a distinct file", .{name});
        }
    }
}

fn validateHairAppearance(value: data.CharacterHairAppearance, detail: *data.CharacterAssetDiagnostic) !void {
    if (!std.math.isFinite(value.length_m) or value.length_m < 0 or value.length_m > 2) {
        return invalid(detail, "hair appearance.length_m: expected 0..2 meters", .{});
    }
}

fn prepareImage(
    memory: std.mem.Allocator,
    definition: data.CharacterArtImage,
    detail: *data.CharacterAssetDiagnostic,
) !Image {
    if (!relativePath(definition.source) or !relativePath(definition.file)) {
        return invalid(detail, "art image: invalid relative path", .{});
    }
    for (definition.pivot) |value| {
        if (!std.math.isFinite(value) or value < 0 or value > 10000) {
            return invalid(detail, "art image.pivot: invalid source coordinate", .{});
        }
    }
    return .{
        .definition = definition,
        .path = try std.fs.path.join(memory, &.{ std.fs.path.dirname(data.characterArtPath).?, definition.file }),
    };
}

fn prepareKnife(
    memory: std.mem.Allocator,
    definition: data.CharacterKnife,
    detail: *data.CharacterAssetDiagnostic,
) !Knife {
    for (definition.blade_base ++ definition.blade_tip ++ definition.second_grip) |coordinate| {
        if (!std.math.isFinite(coordinate) or coordinate < 0 or coordinate > 10000) {
            return invalid(detail, "knife: invalid blade coordinate", .{});
        }
    }
    if (definition.blade_base[0] != definition.image.pivot[0] or
        definition.blade_tip[0] != definition.image.pivot[0] or
        definition.blade_base[1] <= definition.image.pivot[1] or
        definition.blade_tip[1] <= definition.blade_base[1] + 1)
    {
        return invalid(detail, "knife: expected a straight blade below the grip", .{});
    }
    if (definition.second_grip[0] != definition.image.pivot[0] or
        definition.second_grip[1] >= definition.image.pivot[1] or
        std.mem.eql(u8, definition.buried_file, definition.image.file) or
        std.mem.eql(u8, definition.horizontal_file, definition.image.file) or
        std.mem.eql(u8, definition.horizontal_file, definition.buried_file))
    {
        return invalid(detail, "knife: expected a second grip above the first and distinct images", .{});
    }
    var buried = definition.image;
    buried.file = definition.buried_file;
    var horizontal = definition.image;
    horizontal.file = definition.horizontal_file;
    return .{
        .definition = definition,
        .image = try prepareImage(memory, definition.image, detail),
        .buried = try prepareImage(memory, buried, detail),
        .horizontal = try prepareImage(memory, horizontal, detail),
    };
}

fn prepareHair(
    memory: std.mem.Allocator,
    definition: data.CharacterHairData,
    ids: std.StringHashMapUnmanaged(usize),
    bindings: []const Binding,
    detail: *data.CharacterAssetDiagnostic,
) !Hair {
    const head = ids.get(definition.head_binding) orelse {
        return invalid(detail, "hair.head_binding: unknown binding", .{});
    };
    if (bindings[head].anchor != .neck or bindings[head].axis[0] != .neck or
        bindings[head].axis[1] != .head)
    {
        return invalid(detail, "hair.head_binding: expected neck-to-head artwork", .{});
    }
    if (definition.anchors.len == 0 or definition.anchors.len > 64) {
        return invalid(detail, "hair.anchors: expected 1..64 named anchors", .{});
    }
    try character_hair.validate(definition.motion, detail);
    try validateHairAppearance(definition.default, detail);
    var players: std.AutoHashMapUnmanaged(usize, data.CharacterHairAppearance) = .empty;
    for (definition.players) |entry| {
        try validateHairAppearance(entry.appearance, detail);
        if (players.contains(entry.player_id)) {
            return invalid(detail, "hair.players: duplicate player_id {d}", .{entry.player_id});
        }
        try players.put(memory, entry.player_id, entry.appearance);
    }
    for (definition.lock.source_size) |value| {
        if (!std.math.isFinite(value) or value < 1 or value > 10000) {
            return invalid(detail, "hair.lock.source_size: expected 1..10000 pixels", .{});
        }
    }
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (definition.anchors) |anchor| {
        if (anchor.id.len == 0 or anchor.id.len > 96 or names.contains(anchor.id)) {
            return invalid(detail, "hair.anchors: empty, duplicate or too long id", .{});
        }
        try names.put(memory, anchor.id, {});
        for (anchor.position) |value| {
            if (!std.math.isFinite(value) or value < 0 or value > 10000) {
                return invalid(detail, "hair.anchors.{s}.position: invalid head coordinate", .{anchor.id});
            }
        }
        if (!std.math.isFinite(anchor.angle_radians) or @abs(anchor.angle_radians) > std.math.pi) {
            return invalid(detail, "hair.anchors.{s}.angle_radians: expected -pi..pi", .{anchor.id});
        }
        if (!std.math.isFinite(anchor.width_m) or anchor.width_m < 0.001 or anchor.width_m > 0.2) {
            return invalid(detail, "hair.anchors.{s}.width_m: expected 0.001..0.2 meters", .{anchor.id});
        }
        if (!std.math.isFinite(anchor.length_scale) or anchor.length_scale <= 0 or anchor.length_scale > 2) {
            return invalid(detail, "hair.anchors.{s}.length_scale: expected >0..2", .{anchor.id});
        }
    }
    return .{
        .definition = definition,
        .head_binding = head,
        .scalp = try prepareImage(memory, definition.scalp, detail),
        .lock = try prepareImage(memory, definition.lock.image, detail),
        .players = players,
    };
}

// Consumes parsed data on both success and failure; preparation needs no GPU.
pub fn prepare(files: data.CharacterArtData, rig: animation.Rig, detail: *data.CharacterAssetDiagnostic) !Pack {
    var arena = files.arena;
    errdefer arena.deinit();
    const memory = arena.allocator();
    const file = files.manifest;
    detail.* = .{ .file = data.characterArtPath };
    if (file.schema_version != 1 or !std.mem.eql(u8, file.rig, rig.id)) return invalid(detail, "art schema or rig does not match", .{});
    if (file.id.len == 0 or file.parts.map.count() == 0 or file.parts.map.count() > 64) return invalid(detail, "art needs an id and 1..64 parts", .{});
    if (file.bindings.len == 0 or file.bindings.len > 64) return invalid(detail, "bindings: expected 1..64 entries", .{});
    if (!std.math.isFinite(file.far_skin_multiplier) or file.far_skin_multiplier < 0 or file.far_skin_multiplier > 1) return invalid(detail, "far_skin_multiplier: expected 0..1", .{});
    if (!std.mem.eql(u8, file.weapon_hand.attachment, "weapon_hand")) return invalid(detail, "weapon_hand.attachment: must use the gameplay weapon_hand attachment", .{});
    const attachment = rig.attachments.get(file.weapon_hand.attachment) orelse return invalid(detail, "weapon_hand: unknown attachment", .{});
    if (attachment.joint != .left_hand and attachment.joint != .right_hand) return invalid(detail, "weapon_hand: attachment must use a hand joint", .{});
    const grip_part = file.parts.map.getIndex(file.weapon_hand.part) orelse return invalid(detail, "weapon_hand: unknown part", .{});
    const parts = try memory.alloc(Part, file.parts.map.count());
    const folder = std.fs.path.dirname(data.characterArtPath).?; // Constant path has a parent.
    for (file.parts.map.keys(), file.parts.map.values(), parts) |name, definition, *part| {
        try validatePart(name, definition, detail);
        part.* = .{ .definition = definition, .paths = .{
            try std.fs.path.join(memory, &.{ folder, definition.layers[0].file }),
            try std.fs.path.join(memory, &.{ folder, definition.layers[1].file }),
        } };
        if (definition.gib_blood == null) continue; // Older packs have no severed-end artwork.
        part.gib_blood_path = try std.fs.path.join(memory, &.{ folder, definition.gib_blood.? });
    }
    const bindings = try memory.alloc(Binding, file.bindings.len);
    var ids: std.StringHashMapUnmanaged(usize) = .empty;
    for (file.bindings, bindings, 0..) |definition, *binding, index| {
        if (definition.id.len == 0 or definition.id.len > 96 or ids.contains(definition.id)) return invalid(detail, "bindings: empty, duplicate or too long id", .{});
        try ids.put(memory, definition.id, index);
        const part_index = file.parts.map.getIndex(definition.part) orelse return invalid(detail, "bindings.{s}: unknown part", .{definition.id});
        if (definition.axis[0] == definition.axis[1]) return invalid(detail, "bindings.{s}: degenerate joint axis", .{definition.id});
        const weight = definition.survival_weight;
        if (!std.math.isFinite(weight) or weight < 0 or weight > 1) {
            return invalid(detail, "bindings.{s}.survival_weight: expected 0..1", .{definition.id});
        }
        binding.* = .{
            .part = part_index,
            .anchor = definition.anchor,
            .axis = definition.axis,
            .depth = definition.depth,
            .survival_weight = weight,
        };
        const part = parts[part_index].definition;
        const end = rig.joints[@intFromEnum(definition.axis[1])];
        // Only a direct bone anchored at its root specifies a matching length.
        // Decorative parts such as the head and waistband have their own scale.
        if (definition.length_mode == .rig_bone) {
            if (definition.anchor != definition.axis[0] or end.parent != definition.axis[0]) return invalid(detail, "bindings.{s}: rig_bone needs a direct bone anchored at its root", .{definition.id});
            const length = vec.magnitude(vec.subtract(point(part.pivot), point(part.axis_end))) * part.meters_per_pixel;
            if (@abs(length - rig.lengths[@intFromEnum(end.id)]) > 0.0001) return invalid(detail, "bindings.{s}: source length differs from rig", .{definition.id});
        }
        if (part.contacts == null) continue;
        const contacts = part.contacts.?;
        if ((definition.anchor != .left_ankle and definition.anchor != .right_ankle) or end.parent != definition.anchor) return invalid(detail, "bindings.{s}: contacts require an ankle and heel/toe axis", .{definition.id});
        const heel = rig.joints[@intFromEnum(definition.axis[0])];
        if (heel.parent != end.id) return invalid(detail, "bindings.{s}: contacts require heel-to-toe direction", .{definition.id});
        for ([_][2]f32{ contacts.toe, contacts.heel }, [_]vec.Vec2{ end.rest_offset, vec.add(end.rest_offset, heel.rest_offset) }) |source, local| {
            const actual = vec.mul(vec.subtract(point(source), point(part.pivot)), part.meters_per_pixel);
            if (vec.magnitude(vec.subtract(actual, .{ .x = local.x, .y = -local.y })) > 0.0001) return invalid(detail, "bindings.{s}: foot contact differs from rig", .{definition.id});
        }
    }
    var joint_total: usize = 0;
    for (file.bindings, bindings) |definition, *binding| {
        if (definition.ragdoll == null) continue;
        const joint = definition.ragdoll.?;
        const parent = ids.get(joint.parent) orelse {
            return invalid(detail, "bindings.{s}.ragdoll: unknown parent", .{definition.id});
        };
        const lower = joint.limits[0];
        const upper = joint.limits[1];
        if (!std.math.isFinite(joint.reference_angle) or
            !std.math.isFinite(lower) or !std.math.isFinite(upper) or
            lower > upper or lower < -3.1 or upper > 3.1)
        {
            return invalid(detail, "bindings.{s}.ragdoll: invalid angle limits", .{definition.id});
        }
        binding.ragdoll = .{
            .parent = parent,
            .reference_angle = joint.reference_angle,
            .limits = joint.limits,
        };
        joint_total += 1;
    }
    // Older packs may omit ragdolls; a supplied graph must be one connected tree.
    if (joint_total != 0 and joint_total != bindings.len - 1) {
        return invalid(detail, "bindings.ragdoll: expected exactly one root", .{});
    }
    for (bindings, 0..) |_, start| {
        var cursor = start;
        var visited: usize = 0;
        while (bindings[cursor].ragdoll != null) {
            if (visited == bindings.len) {
                return invalid(detail, "bindings.ragdoll: cyclic parent chain", .{});
            }
            cursor = bindings[cursor].ragdoll.?.parent;
            visited += 1;
        }
    }
    var order: [2][]DrawItem = undefined;
    for ([_]bool{ false, true }, 0..) |facing, facing_index| {
        order[facing_index] = try memory.alloc(DrawItem, file.draw_order.len);
        var seen = [_]bool{false} ** 64;
        var weapon_seen = [_]bool{false} ** 2;
        var holster_seen = false;
        for (file.draw_order, order[facing_index]) |name, *item| {
            if (std.mem.eql(u8, name, "holstered_weapon")) {
                if (holster_seen) return invalid(detail, "draw_order: duplicate holstered weapon", .{});
                holster_seen = true;
                item.* = .holster;
                continue;
            }
            const near = std.mem.startsWith(u8, name, "near_");
            const far = std.mem.startsWith(u8, name, "far_");
            var buffer: [128]u8 = undefined;
            const depth: data.CharacterArtDepth = if (far == facing) .right else .left;
            const resolved = if (near or far) std.fmt.bufPrint(&buffer, "{s}_{s}", .{ @tagName(depth), name[if (far) 4 else 5..] }) catch return invalid(detail, "draw_order: name is too long", .{}) else name;
            if ((near or far) and std.mem.eql(u8, name[if (far) 4 else 5..], "weapon")) {
                const index: usize = if (depth == .right) 1 else 0;
                if (weapon_seen[index]) return invalid(detail, "draw_order: duplicate weapon depth", .{});
                weapon_seen[index] = true;
                item.* = .{ .weapon = depth };
                continue;
            }
            const index = ids.get(resolved) orelse return invalid(detail, "draw_order: unknown binding {s}", .{resolved});
            if (seen[index]) return invalid(detail, "draw_order: duplicate binding {s}", .{resolved});
            seen[index] = true;
            item.* = .{ .part = index };
        }
        for (seen[0..bindings.len]) |present| {
            if (!present) return invalid(detail, "draw_order: missing binding", .{});
        }
        if (!weapon_seen[0] or !weapon_seen[1] or !holster_seen) return invalid(detail, "draw_order: needs both weapon depths and holstered_weapon", .{});
    }
    const hair = if (file.hair == null) null else try prepareHair(memory, file.hair.?, ids, bindings, detail);
    return .{
        .arena = arena,
        .id = file.id,
        .parts = parts,
        .bindings = bindings,
        .order = order,
        .grip_part = grip_part,
        .weapon_joint = attachment.joint,
        .far_skin_multiplier = file.far_skin_multiplier,
        .hair = hair,
        .knife = if (file.knife == null) null else try prepareKnife(memory, file.knife.?, detail),
    };
}

fn loadImage(image: *Image, scale: f32, detail: *data.CharacterAssetDiagnostic) !void {
    image.sprite_id = sprite.createFromImgWithAtlasProfile(
        image.path,
        .{ .x = scale, .y = scale },
        vec.zero,
        .standalone,
        .world_meters,
        .preserve_detail,
        .{},
    ) catch |err| {
        return invalid(detail, "art image {s}: {s}", .{ image.path, @errorName(err) });
    };
    const visual = sprite.getSprite(image.sprite_id.?).?; // Just created and owned by this candidate.
    const pivot = image.definition.pivot;
    if (pivot[0] > @as(f32, @floatFromInt(visual.surface.w)) or
        pivot[1] > @as(f32, @floatFromInt(visual.surface.h)))
    {
        return invalid(detail, "art image {s}: pivot outside image canvas", .{image.path});
    }
}

// Owned textures bypass the immutable path cache so SVG edits reload as well as
// JSON edits. They also survive level atlas resets without retaining old slots.
pub fn loadSprites(pack: *Pack, detail: *data.CharacterAssetDiagnostic) !void {
    for (pack.parts) |*part| {
        const paths = [_]?[]const u8{ part.paths[0], part.paths[1], part.gib_blood_path };
        const ids = [_]*?u64{ &part.sprites[0], &part.sprites[1], &part.gib_blood_sprite };
        const scale: vec.Vec2 = .{
            .x = part.definition.meters_per_pixel,
            .y = part.definition.meters_per_pixel,
        };
        for (ids, paths) |id, path| {
            if (path == null) continue; // The blood overlay is optional.
            id.* = sprite.createFromImgWithAtlasProfile(
                path.?,
                scale,
                vec.zero,
                .standalone,
                .world_meters,
                .preserve_detail,
                .{},
            ) catch |err| {
                return invalid(detail, "image {s}: {s}", .{ path.?, @errorName(err) });
            };
        }
        const skin = sprite.getSprite(part.sprites[0].?).?; // Just created; this pack owns the IDs.
        for ([_]?u64{ part.sprites[1], part.gib_blood_sprite }) |id| {
            if (id == null) continue;
            const layer = sprite.getSprite(id.?).?;
            if (skin.surface.w != layer.surface.w or skin.surface.h != layer.surface.h) {
                return invalid(detail, "{s}: layer canvases differ", .{part.paths[0]});
            }
        }
        for ([_][2]f32{ part.definition.pivot, part.definition.axis_end }) |p| {
            if (p[0] > @as(f32, @floatFromInt(skin.surface.w)) or p[1] > @as(f32, @floatFromInt(skin.surface.h))) return invalid(detail, "{s}: pivot/axis outside image canvas", .{part.paths[0]});
        }
    }
    if (pack.knife != null) {
        const scale = pack.parts[pack.grip_part].definition.meters_per_pixel;
        const knife = &pack.knife.?;
        try loadImage(&knife.image, scale, detail);
        try loadImage(&knife.buried, scale, detail);
        try loadImage(&knife.horizontal, scale, detail);
        const canvas = sprite.getSprite(knife.image.sprite_id.?).?.surface;
        for ([_]Image{ knife.buried, knife.horizontal }) |image| {
            const other_canvas = sprite.getSprite(image.sprite_id.?).?.surface;
            if (other_canvas.w != canvas.w or other_canvas.h != canvas.h) {
                return invalid(detail, "knife: image canvases differ", .{});
            }
        }
        for ([_][2]f32{ knife.definition.blade_base, knife.definition.blade_tip, knife.definition.second_grip }) |coordinate| {
            if (coordinate[0] > @as(f32, @floatFromInt(canvas.w)) or
                coordinate[1] > @as(f32, @floatFromInt(canvas.h)))
            {
                return invalid(detail, "knife: blade outside image canvas", .{});
            }
        }
    }
    if (pack.hair == null) return; // Legacy packs have no hair decoration.
    const hair = &pack.hair.?;
    const head = pack.parts[pack.bindings[hair.head_binding].part];
    try loadImage(&hair.scalp, head.definition.meters_per_pixel, detail);
    const canvas = sprite.getSprite(head.sprites[0].?).?.surface;
    for (hair.definition.anchors) |anchor| {
        if (anchor.position[0] > @as(f32, @floatFromInt(canvas.w)) or
            anchor.position[1] > @as(f32, @floatFromInt(canvas.h)))
        {
            return invalid(detail, "hair.anchors.{s}: position outside head canvas", .{anchor.id});
        }
    }
    try loadImage(&hair.lock, head.definition.meters_per_pixel, detail);
    const lock_canvas = sprite.getSprite(hair.lock.sprite_id.?).?.surface;
    const tip = hair.lock.definition.pivot[1] + hair.definition.lock.source_size[1];
    if (tip > @as(f32, @floatFromInt(lock_canvas.h))) {
        return invalid(detail, "hair.lock.source_size: tip outside image canvas", .{});
    }
}

pub fn destroy(pack: *Pack) void {
    defer pack.arena.deinit();
    for (pack.parts) |part| {
        for ([_]?u64{ part.sprites[0], part.sprites[1], part.gib_blood_sprite }) |id| {
            if (id == null) continue; // Preparation and failed loads can own no texture.
            sprite.destroy(id.?);
        }
    }
    if (pack.knife != null) {
        const knife = pack.knife.?;
        for ([_]?u64{ knife.image.sprite_id, knife.buried.sprite_id, knife.horizontal.sprite_id }) |id| {
            if (id == null) continue; // Preparation or partial loading owns no image yet.
            sprite.destroy(id.?);
        }
    }
    const hair = pack.hair orelse return;
    // Each shared texture is owned once, even when many anchors draw the lock.
    for ([_]?u64{ hair.scalp.sprite_id, hair.lock.sprite_id }) |id| {
        if (id == null) continue; // Preparation or partial loading.
        sprite.destroy(id.?);
    }
}

pub fn install(replacement: Pack) void {
    // Replacement bodies are already registered; only retire the old assets.
    var previous = assets;
    assets = replacement;
    character_hair.resetAll();
    if (previous == null) return;
    destroy(&previous.?);
}

pub fn cleanup() void {
    character_hair.cleanup();
    bodyParts.clearAndFree(allocator);
    if (assets == null) return;
    destroy(&assets.?);
    assets = null;
}

pub fn worldJoints(rig: animation.Rig, frame: animation.FramePose) [joint_count]vec.Vec2 {
    var points: [joint_count]vec.Vec2 = undefined;
    for (frame.pose.joints, &points) |local, *world| world.* = animation.toWorld(rig, local, frame.body, frame.facing_right);
    return points;
}

// Pure placement from the final pose. It does not change controls, IK or contacts.
pub fn placePart(pack: *const Pack, binding_index: usize, points: [joint_count]vec.Vec2, frame: animation.FramePose, carrying: bool) PlacedPart {
    const binding = pack.bindings[binding_index];
    var part_index = binding.part;
    var position = points[@intFromEnum(binding.anchor)];
    var direction = vec.subtract(points[@intFromEnum(binding.axis[1])], points[@intFromEnum(binding.axis[0])]);
    var facing = frame.facing_right;
    if (pack.knife != null and frame.knife != null and
        (binding.anchor == frame.knife.?.joint or
            binding.anchor == frame.knife.?.second_hand))
    {
        part_index = pack.grip_part;
        facing = frame.knife.?.side < 0;
        const angle = knifeAngle(frame.knife.?.side, frame.knife.?.horizontal);
        const sign: f32 = if (facing) 1 else -1;
        direction = .{ .x = @cos(angle) * sign, .y = @sin(angle) * sign };
    }
    // The gun travels independently toward its holster during wall bracing;
    // keep the open hand on the solved wrist throughout either transition.
    if (carrying and !frame.weapon_stowed and frame.weapon_stow_weight == 0 and binding.anchor == pack.weapon_joint) {
        part_index = pack.grip_part;
        position = frame.weapon.position;
        facing = frame.weapon_facing_right;
        const sign: f32 = if (facing) 1 else -1;
        direction = .{ .x = @cos(frame.weapon.angle) * sign, .y = @sin(frame.weapon.angle) * sign };
    }
    const part = pack.parts[part_index].definition;
    const source = vec.subtract(point(part.axis_end), point(part.pivot));
    const source_angle = std.math.atan2(source.y, source.x * @as(f32, if (facing) 1 else -1));
    return .{ .part = part_index, .position = position, .angle = std.math.atan2(direction.y, direction.x) - source_angle, .facing_right = facing, .far = isFar(binding.depth, frame.facing_right) };
}

pub fn knifeAngle(side: i8, horizontal: bool) f32 {
    const angle: f32 = if (horizontal) std.math.pi / 2.0 else std.math.pi / 4.0;
    return -@as(f32, @floatFromInt(side)) * angle;
}

// The middle of the blade meets the wall; the grip remains outside it.
pub fn knifeContactOffset(pack: *const Pack, side: i8, horizontal: bool) vec.Vec2 {
    const knife = pack.knife orelse return vec.zero;
    const middle = vec.mul(vec.add(point(knife.definition.blade_base), point(knife.definition.blade_tip)), 0.5);
    return knifePointOffset(pack, side, horizontal, .{ middle.x, middle.y });
}

pub fn knifePointOffset(pack: *const Pack, side: i8, horizontal: bool, source: [2]f32) vec.Vec2 {
    const knife = pack.knife orelse return vec.zero;
    const scale = pack.parts[pack.grip_part].definition.meters_per_pixel;
    var local = vec.mul(vec.subtract(point(source), point(knife.image.definition.pivot)), scale);
    if (side > 0) local.x = -local.x;
    const rotation = box2d.c.b2MakeRot(knifeAngle(side, horizontal));
    return vec.fromBox2d(box2d.c.b2RotateVector(rotation, vec.toBox2d(local)));
}

pub fn placeKnife(
    pack: *const Pack,
    points: [joint_count]vec.Vec2,
    frame: animation.FramePose,
) ?ImagePlacement {
    if (pack.knife == null) return null; // Optional artwork.
    const grip = frame.knife orelse return null;
    const scale = pack.parts[pack.grip_part].definition.meters_per_pixel;
    return .{
        .position = points[@intFromEnum(grip.joint)],
        .angle = knifeAngle(grip.side, grip.horizontal),
        .scale = .{ .x = scale, .y = scale },
        .facing_right = grip.side < 0,
    };
}

pub fn skinColor(color: sprite.Color, multiplier: f32) sprite.Color {
    return .{ .r = @intFromFloat(@round(@as(f32, @floatFromInt(color.r)) * multiplier)), .g = @intFromFloat(@round(@as(f32, @floatFromInt(color.g)) * multiplier)), .b = @intFromFloat(@round(@as(f32, @floatFromInt(color.b)) * multiplier)) };
}

pub fn hairForPlayer(pack: *const Pack, player_id: usize) ?data.CharacterHairAppearance {
    if (pack.hair == null) return null; // A pack can intentionally omit hair.
    const hair = pack.hair.?;
    return hair.players.get(player_id) orelse hair.definition.default;
}

pub fn hairAnchor(pack: *const Pack, head: PlacedPart, anchor: data.CharacterHairAnchor) vec.Vec2 {
    const part = pack.parts[head.part].definition;
    var local = vec.mul(vec.subtract(point(anchor.position), point(part.pivot)), part.meters_per_pixel);
    if (!head.facing_right) local.x = -local.x;
    const rotation = box2d.c.b2MakeRot(head.angle);
    return vec.add(head.position, vec.fromBox2d(box2d.c.b2RotateVector(rotation, vec.toBox2d(local))));
}

pub fn placeHairLock(
    pack: *const Pack,
    head: PlacedPart,
    anchor: data.CharacterHairAnchor,
    appearance: data.CharacterHairAppearance,
) ImagePlacement {
    const source_size = pack.hair.?.definition.lock.source_size; // Caller resolved the hair style.
    return .{
        .position = hairAnchor(pack, head, anchor),
        .angle = head.angle + anchor.angle_radians * @as(f32, if (head.facing_right) 1 else -1),
        .scale = .{
            .x = anchor.width_m / source_size[0],
            .y = appearance.length_m * anchor.length_scale / source_size[1],
        },
        .facing_right = head.facing_right,
    };
}

fn drawImage(image: Image, placed: ImagePlacement, color: sprite.Color) !void {
    const id = image.sprite_id orelse {
        std.log.warn("character_art.drawImage: image {s} is not loaded", .{image.path});
        return;
    };
    const original = sprite.getSprite(id) orelse {
        std.log.warn("character_art.drawImage: sprite {d} is missing", .{id});
        return;
    };
    const scale = vec.mul(placed.scale, conv.met2pix);
    const visual = try sprite.scaledForDraw(original, scale);
    const pivot: vec.IVec2 = .{
        .x = @intFromFloat(@round(image.definition.pivot[0] * scale.x)),
        .y = @intFromFloat(@round(image.definition.pivot[1] * scale.y)),
    };
    const position = camera.relativePosition(conv.m2Pixel(vec.toBox2d(placed.position)));
    const placement = sprite.placeAtAnchor(visual, pivot, position, placed.angle, !placed.facing_right);
    try sprite.drawPlacedTinted(visual, placement, color);
}

fn drawHairLayer(
    pack: *const Pack,
    maybe_head: ?PlacedPart,
    appearance: ?data.CharacterHairAppearance,
    layer: data.CharacterHairLayer,
    owner: ?box2d.c.b2BodyId,
) !void {
    if (pack.hair == null or appearance == null) {
        return; // Optional style/appearance.
    }
    const head = maybe_head orelse return;
    const hair = pack.hair.?;
    const value = appearance.?;
    if (layer == .front) {
        const scale = pack.parts[head.part].definition.meters_per_pixel;
        try drawImage(hair.scalp, .{
            .position = head.position,
            .angle = head.angle,
            .scale = .{ .x = scale, .y = scale },
            .facing_right = head.facing_right,
        }, value.color);
    }
    if (value.length_m == 0) return; // A zero-length cut keeps scalp coverage.
    for (hair.definition.anchors, 0..) |anchor, index| {
        if (anchor.layer != layer) continue;
        const placed = placeHairLock(pack, head, anchor, value);
        if (try character_hair.drawLock(owner, index, hair.lock, placed, value.color)) continue;
        try drawImage(hair.lock, placed, value.color);
    }
}

pub fn draw(player_id: usize, rig: animation.Rig, frame: animation.FramePose) !void {
    if (assets == null) {
        std.log.warn("character_art.draw: artwork is not loaded", .{});
        return;
    }
    const pack = &assets.?;
    const p = player.players.get(player_id) orelse {
        std.log.warn("character_art.draw: player {d} is missing", .{player_id});
        return;
    };
    const carrying = player.usesProceduralWeapon(p);
    const points = worldJoints(rig, frame);
    const knife = placeKnife(pack, points, frame);
    var knife_drawn = false;
    const weapon_depth: data.CharacterArtDepth = if (pack.weapon_joint == .right_hand) .right else .left;
    const appearance = hairForPlayer(pack, player_id);
    const head = if (pack.hair == null) null else placePart(pack, pack.hair.?.head_binding, points, frame, false);
    try drawHairLayer(pack, head, appearance, .back, p.bodyId);
    for (pack.order[@intFromBool(frame.facing_right)]) |item| {
        switch (item) {
            .holster => {
                if (carrying and frame.weapon_stowed) try player.drawProceduralWeapon(player_id, frame.weapon, frame.weapon_facing_right);
            },
            .weapon => |depth| {
                if (carrying and !frame.weapon_stowed and depth == weapon_depth) try player.drawProceduralWeapon(player_id, frame.weapon, frame.weapon_facing_right);
            },
            .part => |index| {
                // Draw before the first gripping hand, so both sets of fingers cover
                // the handle during a push regardless of which arm is nearer.
                if (knife != null and !knife_drawn and
                    (pack.bindings[index].anchor == frame.knife.?.joint or
                        pack.bindings[index].anchor == frame.knife.?.second_hand))
                {
                    const grip = frame.knife.?;
                    const artwork = pack.knife.?;
                    const exposed = if (grip.horizontal and !grip.show_tip) artwork.horizontal else artwork.image;
                    try drawImage(exposed, knife.?, .{ .r = 255, .g = 255, .b = 255 });
                    if (grip.show_tip) {
                        try drawImage(artwork.buried, knife.?, .{ .r = 255, .g = 255, .b = 255 });
                    }
                    knife_drawn = true;
                }
                const placed = placePart(pack, index, points, frame, carrying);
                const tint = skinColor(p.color, if (placed.far) pack.far_skin_multiplier else 1);
                try drawPart(.{
                    .part = placed.part,
                    .facing_right = placed.facing_right,
                    .skin_color = tint,
                }, placed.position, placed.angle, null);
            },
        }
    }
    try drawHairLayer(pack, head, appearance, .front, p.bodyId);
}

// Connected heads use scene hair passes so torso/arm pool insertion order cannot
// cover the front locks. Isolated giblet heads keep their hair in drawPart.
pub fn connectedHairFrame(body_id: box2d.c.b2BodyId) ?HairFrame {
    const visual = bodyParts.get(body_id) orelse return null;
    if (visual.severed or visual.hair == null) {
        return null;
    }
    const e = entity.getEntity(body_id) orelse {
        std.log.warn("character_art.connectedHairFrame: head entity is missing", .{});
        return null;
    };
    if (!e.enabled) return null; // Pool entries remain registered while inactive.
    const state = box2d.getInterpolatedState(e.state, box2d.getState(body_id));
    return .{
        .head = .{
            .part = visual.part,
            .position = vec.fromBox2d(state.pos),
            .angle = state.rotAngle,
            .facing_right = visual.facing_right,
            .far = false,
        },
        .appearance = visual.hair.?,
    };
}

pub fn drawAllConnectedHair(layer: data.CharacterHairLayer) !void {
    if (assets == null) return;
    const pack = &assets.?;
    for (bodyParts.keys()) |body_id| {
        const frame = connectedHairFrame(body_id) orelse continue;
        try drawHairLayer(pack, frame.head, frame.appearance, layer, body_id);
    }
}

// Entity drawing supplies its existing interpolated transform and draw order.
pub fn drawBodyPart(bodyId: box2d.c.b2BodyId, position: vec.Vec2, angle: f32) !bool {
    const visual = bodyParts.get(bodyId) orelse return false;
    try drawPart(visual, position, angle, bodyId);
    return true;
}

// Living and detached parts share placement; only severed pieces draw blood.
pub fn drawPart(part_visual: DetachedPart, position: vec.Vec2, angle: f32, owner: ?box2d.c.b2BodyId) !void {
    if (assets == null or part_visual.part >= assets.?.parts.len) {
        std.log.warn("character_art.drawPart: detached artwork is unavailable", .{});
        return;
    }
    const part = assets.?.parts[part_visual.part];
    const placed_head: PlacedPart = .{
        .part = part_visual.part,
        .position = position,
        .angle = angle,
        .facing_right = part_visual.facing_right,
        .far = false,
    };
    const hair = if (part_visual.severed) part_visual.hair else null;
    try drawHairLayer(&assets.?, placed_head, hair, .back, owner);
    const anchor = camera.relativePosition(conv.m2Pixel(vec.toBox2d(position)));
    const scale = part.definition.meters_per_pixel;
    const pivot: vec.IVec2 = .{
        .x = @intFromFloat(@round(part.definition.pivot[0] * scale * conv.met2pix)),
        .y = @intFromFloat(@round(part.definition.pivot[1] * scale * conv.met2pix)),
    };
    for ([_]?u64{ part.sprites[0], part.sprites[1], part.gib_blood_sprite }, 0..) |id, layer| {
        if (layer == 2 and (!part_visual.severed or part.gib_blood_path == null)) {
            continue;
        }
        if (id == null) {
            std.log.warn("character_art.drawPart: layer {d} has no sprite", .{layer});
            return;
        }
        const visual = sprite.getSprite(id.?) orelse {
            std.log.warn("character_art.drawPart: sprite {d} is missing", .{id.?});
            return;
        };
        const placement = sprite.placeAtAnchor(visual, pivot, anchor, angle, !part_visual.facing_right);
        const tint: ?sprite.Color = switch (layer) {
            0 => part_visual.skin_color,
            2 => try blood.currentColor(),
            else => null,
        };
        try sprite.drawPlacedTinted(visual, placement, tint);
    }
    try drawHairLayer(&assets.?, placed_head, hair, .front, owner);
}
