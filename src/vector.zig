pub const IVec2 = struct {
    x: i32,
    y: i32,
};

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

pub fn equals(a: IVec2, b: IVec2) bool {
    return a.x == b.x and a.y == b.y;
}
