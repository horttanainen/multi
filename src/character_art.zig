const std = @import("std");
const animation = @import("character_animation.zig");
const data = @import("data.zig");
const sprite = @import("sprite.zig");
const player = @import("player.zig");
const vec = @import("vector.zig");
const conv = @import("conversion.zig");
const camera = @import("camera.zig");

const joint_count = std.meta.fields(animation.Joint).len;
const invalid = data.invalidCharacterAsset;
pub const Part = struct { definition: data.CharacterArtPart, paths: [2][]const u8, sprites: [2]?u64 = .{ null, null } };
pub const Binding = struct { part: usize, anchor: animation.Joint, axis: [2]animation.Joint, depth: data.CharacterArtDepth };
pub const DrawItem = union(enum) { part: usize, weapon: data.CharacterArtDepth, holster };
pub const Pack = struct {
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    parts: []Part,
    bindings: []Binding,
    order: [2][]DrawItem,
    grip_part: usize,
    weapon_joint: animation.Joint,
    far_skin_multiplier: f32,
};
pub const PlacedPart = struct { part: usize, position: vec.Vec2, angle: f32, facing_right: bool, far: bool };
pub var assets: ?Pack = null;

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
    }
    const bindings = try memory.alloc(Binding, file.bindings.len);
    var ids: std.StringHashMapUnmanaged(usize) = .empty;
    for (file.bindings, bindings, 0..) |definition, *binding, index| {
        if (definition.id.len == 0 or definition.id.len > 96 or ids.contains(definition.id)) return invalid(detail, "bindings: empty, duplicate or too long id", .{});
        try ids.put(memory, definition.id, index);
        const part_index = file.parts.map.getIndex(definition.part) orelse return invalid(detail, "bindings.{s}: unknown part", .{definition.id});
        if (definition.axis[0] == definition.axis[1]) return invalid(detail, "bindings.{s}: degenerate joint axis", .{definition.id});
        binding.* = .{ .part = part_index, .anchor = definition.anchor, .axis = definition.axis, .depth = definition.depth };
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
    return .{ .arena = arena, .id = file.id, .parts = parts, .bindings = bindings, .order = order, .grip_part = grip_part, .weapon_joint = attachment.joint, .far_skin_multiplier = file.far_skin_multiplier };
}

// Owned textures bypass the immutable path cache so SVG edits reload as well as
// JSON edits. They also survive level atlas resets without retaining old slots.
pub fn loadSprites(pack: *Pack, detail: *data.CharacterAssetDiagnostic) !void {
    for (pack.parts) |*part| {
        for (&part.sprites, part.paths) |*id, path| {
            id.* = sprite.createFromImgWithAtlasProfile(path, .{ .x = part.definition.meters_per_pixel, .y = part.definition.meters_per_pixel }, vec.zero, .standalone, .world_meters, .preserve_detail, .{}) catch |err| {
                return invalid(detail, "image {s}: {s}", .{ path, @errorName(err) });
            };
        }
        const skin = sprite.getSprite(part.sprites[0].?).?; // Just created; this pack owns the IDs.
        const fixed = sprite.getSprite(part.sprites[1].?).?;
        if (skin.surface.w != fixed.surface.w or skin.surface.h != fixed.surface.h) return invalid(detail, "{s}: layer canvases differ", .{part.paths[0]});
        for ([_][2]f32{ part.definition.pivot, part.definition.axis_end }) |p| {
            if (p[0] > @as(f32, @floatFromInt(skin.surface.w)) or p[1] > @as(f32, @floatFromInt(skin.surface.h))) return invalid(detail, "{s}: pivot/axis outside image canvas", .{part.paths[0]});
        }
    }
}

pub fn destroy(pack: *Pack) void {
    for (pack.parts) |part| {
        for (part.sprites) |id| {
            if (id == null) continue; // Preparation and failed loads can own no texture.
            sprite.destroy(id.?);
        }
    }
    pack.arena.deinit();
}

pub fn install(replacement: Pack) void {
    cleanup();
    assets = replacement;
}

pub fn cleanup() void {
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

pub fn skinColor(color: sprite.Color, multiplier: f32) sprite.Color {
    return .{ .r = @intFromFloat(@round(@as(f32, @floatFromInt(color.r)) * multiplier)), .g = @intFromFloat(@round(@as(f32, @floatFromInt(color.g)) * multiplier)), .b = @intFromFloat(@round(@as(f32, @floatFromInt(color.b)) * multiplier)) };
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
    const weapon_depth: data.CharacterArtDepth = if (pack.weapon_joint == .right_hand) .right else .left;
    for (pack.order[@intFromBool(frame.facing_right)]) |item| {
        switch (item) {
            .holster => {
                if (carrying and frame.weapon_stowed) try player.drawProceduralWeapon(player_id, frame.weapon, frame.weapon_facing_right);
            },
            .weapon => |depth| {
                if (carrying and !frame.weapon_stowed and depth == weapon_depth) try player.drawProceduralWeapon(player_id, frame.weapon, frame.weapon_facing_right);
            },
            .part => |index| {
                const placed = placePart(pack, index, points, frame, carrying);
                const part = pack.parts[placed.part];
                const anchor = camera.relativePosition(conv.m2Pixel(.{ .x = placed.position.x, .y = placed.position.y }));
                const pivot: vec.IVec2 = .{ .x = @intFromFloat(@round(part.definition.pivot[0] * part.definition.meters_per_pixel * conv.met2pix)), .y = @intFromFloat(@round(part.definition.pivot[1] * part.definition.meters_per_pixel * conv.met2pix)) };
                for (part.sprites, 0..) |id, layer| {
                    const visual = sprite.getSprite(id.?) orelse {
                        std.log.warn("character_art.draw: part sprite {d} is missing", .{id.?});
                        return;
                    };
                    const placement = sprite.placeAtAnchor(visual, pivot, anchor, placed.angle, !placed.facing_right);
                    const tint: ?sprite.Color = if (layer == 0) skinColor(.{ .r = p.color.r, .g = p.color.g, .b = p.color.b }, if (placed.far) pack.far_skin_multiplier else 1) else null;
                    try sprite.drawPlacedTinted(visual, placement, tint);
                }
            },
        }
    }
}
