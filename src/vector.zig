pub const IVec2 = struct {
    x: i32,
    y: i32,
};

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

pub fn iequals(a: IVec2, b: IVec2) bool {
    return a.x == b.x and a.y == b.y;
}

pub fn isubtract(a: IVec2, b: IVec2) IVec2 {
    return .{
        .x = a.x - b.x,
        .y = a.y - b.y,
    };
}

pub fn iadd(a: IVec2, b: IVec2) IVec2 {
    return .{
        .x = a.x + b.x,
        .y = a.y + b.y,
    };
}

pub fn equals(a: Vec2, b: Vec2) bool {
    return a.x == b.x and a.y == b.y;
}

pub fn add(a: Vec2, b: Vec2) Vec2 {
    return .{
        .x = a.x + b.x,
        .y = a.y + b.y,
    };
}

pub fn mul(a: Vec2, b: f32) Vec2 {
    return .{
        .x = a.x * b,
        .y = a.y * b,
    };
}

pub const west: Vec2 = .{ .x = -1, .y = 0 };
pub const east: Vec2 = .{ .x = 1, .y = 0 };
pub const north: Vec2 = .{ .x = 0, .y = 1 };
pub const south: Vec2 = .{ .x = 0, .y = -1 };

pub const zero: Vec2 = .{ .x = 0, .y = 0 };
