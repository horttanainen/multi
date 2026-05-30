const std = @import("std");
const sdl = @import("sdl.zig");
const c = sdl.c;

pub const ATLAS_SIZE: u32 = 8192;

// Skyline bottom-left bin packer.
// Tracks the top edge (skyline) of placed rectangles as a list of (x, y, width) segments.
// For each allocation, finds the position that results in the lowest Y placement.
const MAX_SKYLINE_NODES = 4096;
const MAX_FREE_REGIONS = 4096;

pub const SkylineNode = struct {
    x: u32,
    y: u32,
    width: u32,
};

pub const Region = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const Atlas = struct {
    gpu_texture: *c.SDL_GPUTexture,
    width: u32 = ATLAS_SIZE,
    height: u32 = ATLAS_SIZE,
    nodes: [MAX_SKYLINE_NODES]SkylineNode = undefined,
    node_count: u32 = 0,
    free_regions: [MAX_FREE_REGIONS]Region = undefined,
    free_region_count: u32 = 0,
    generation: u64 = 0,
    checkpoint_nodes: [MAX_SKYLINE_NODES]SkylineNode = undefined,
    checkpoint_node_count: u32 = 0,
    checkpoint_free_regions: [MAX_FREE_REGIONS]Region = undefined,
    checkpoint_free_region_count: u32 = 0,
    checkpoint_generation: u64 = 0,

    pub fn init(self: *Atlas) void {
        self.nodes[0] = .{ .x = 0, .y = 0, .width = self.width };
        self.node_count = 1;
        self.free_region_count = 0;
        self.generation +%= 1;
    }

    pub fn saveCheckpoint(self: *Atlas) void {
        @memcpy(&self.checkpoint_nodes, &self.nodes);
        self.checkpoint_node_count = self.node_count;
        @memcpy(&self.checkpoint_free_regions, &self.free_regions);
        self.checkpoint_free_region_count = self.free_region_count;
        self.checkpoint_generation = self.generation;
    }

    pub fn restoreCheckpoint(self: *Atlas) void {
        @memcpy(&self.nodes, &self.checkpoint_nodes);
        self.node_count = self.checkpoint_node_count;
        @memcpy(&self.free_regions, &self.checkpoint_free_regions);
        self.free_region_count = self.checkpoint_free_region_count;
        self.generation = self.checkpoint_generation;
    }

    /// Check if a rectangle of (w x h) fits when placed starting at skyline node `index`.
    /// Returns the Y coordinate at which it would sit (max Y across spanned nodes), or null if it doesn't fit.
    pub fn rectangleFits(self: *const Atlas, index: u32, w: u32, h: u32) ?u32 {
        const x = self.nodes[index].x;
        if (x + w > self.width) return null;

        var width_left: i64 = @intCast(w);
        var i = index;
        var y: u32 = self.nodes[index].y;

        while (width_left > 0) {
            if (i >= self.node_count) return null;
            y = @max(y, self.nodes[i].y);
            if (y + h > self.height) return null;
            width_left -= @as(i64, @intCast(self.nodes[i].width));
            i += 1;
        }
        return y;
    }

    pub fn allocate(self: *Atlas, w: u32, h: u32) !struct { x: u32, y: u32 } {
        if (self.allocateFromFreeRegion(w, h)) |region| {
            return .{ .x = region.x, .y = region.y };
        }

        // Find best position (bottom-left heuristic: lowest Y, then leftmost X)
        var best_y: u32 = std.math.maxInt(u32);
        var best_x: u32 = std.math.maxInt(u32);
        var best_idx: ?u32 = null;

        for (0..self.node_count) |i| {
            if (self.rectangleFits(@intCast(i), w, h)) |y| {
                const x = self.nodes[i].x;
                if (y < best_y or (y == best_y and x < best_x)) {
                    best_y = y;
                    best_x = x;
                    best_idx = @intCast(i);
                }
            }
        }

        const idx = best_idx orelse return error.AtlasFull;
        self.addSkylineLevel(idx, best_x, best_y + h, w);
        return .{ .x = best_x, .y = best_y };
    }

    pub fn freeRegion(self: *Atlas, x: u32, y: u32, w: u32, h: u32) void {
        if (w == 0 or h == 0) {
            std.log.warn("freeRegion: ignoring invalid {d}x{d} region at ({d},{d})", .{ w, h, x, y });
            return;
        }

        if (self.free_region_count >= MAX_FREE_REGIONS) {
            std.log.warn("freeRegion: free region table full, leaking {d}x{d} region at ({d},{d})", .{ w, h, x, y });
            return;
        }

        self.free_regions[self.free_region_count] = .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
        };
        self.free_region_count += 1;
    }

    fn allocateFromFreeRegion(self: *Atlas, w: u32, h: u32) ?Region {
        var best_index: ?u32 = null;
        var best_area: u64 = std.math.maxInt(u64);

        for (0..self.free_region_count) |i| {
            const region = self.free_regions[i];
            if (region.w < w or region.h < h) continue;

            const area = @as(u64, region.w) * @as(u64, region.h);
            if (area < best_area) {
                best_area = area;
                best_index = @intCast(i);
            }
        }

        if (best_index == null) return null;
        const index = best_index.?;
        const region = self.free_regions[index];
        self.removeFreeRegion(index);
        self.addSplitFreeRegions(region, w, h);

        return .{
            .x = region.x,
            .y = region.y,
            .w = w,
            .h = h,
        };
    }

    fn addSplitFreeRegions(self: *Atlas, region: Region, used_w: u32, used_h: u32) void {
        if (region.w > used_w) {
            self.freeRegion(region.x + used_w, region.y, region.w - used_w, used_h);
        }
        if (region.h > used_h) {
            self.freeRegion(region.x, region.y + used_h, region.w, region.h - used_h);
        }
    }

    fn removeFreeRegion(self: *Atlas, index: u32) void {
        var i = index;
        while (i + 1 < self.free_region_count) : (i += 1) {
            self.free_regions[i] = self.free_regions[i + 1];
        }
        self.free_region_count -= 1;
    }

    /// Insert a new skyline node and trim/remove nodes it covers.
    pub fn addSkylineLevel(self: *Atlas, index: u32, x: u32, y: u32, w: u32) void {
        if (self.node_count >= MAX_SKYLINE_NODES) return;

        // Shift nodes right to make room at `index`
        var j: u32 = self.node_count;
        while (j > index) : (j -= 1) {
            self.nodes[j] = self.nodes[j - 1];
        }
        self.nodes[index] = .{ .x = x, .y = y, .width = w };
        self.node_count += 1;

        // Shrink or remove subsequent nodes that overlap with the new node
        self.trimOverlapping(index);

        self.mergeSkylines();
    }

    pub fn trimOverlapping(self: *Atlas, index: u32) void {
        const check_from = index + 1;
        while (check_from < self.node_count) {
            const prev_end = self.nodes[check_from - 1].x + self.nodes[check_from - 1].width;
            if (self.nodes[check_from].x < prev_end) {
                const shrink = prev_end - self.nodes[check_from].x;
                if (shrink >= self.nodes[check_from].width) {
                    self.removeNode(check_from);
                } else {
                    self.nodes[check_from].x += shrink;
                    self.nodes[check_from].width -= shrink;
                    break;
                }
            } else {
                break;
            }
        }
    }

    pub fn removeNode(self: *Atlas, index: u32) void {
        var k = index;
        while (k + 1 < self.node_count) : (k += 1) {
            self.nodes[k] = self.nodes[k + 1];
        }
        self.node_count -= 1;
    }

    /// Merge adjacent nodes at the same Y level.
    pub fn mergeSkylines(self: *Atlas) void {
        var i: u32 = 0;
        while (i + 1 < self.node_count) {
            if (self.nodes[i].y == self.nodes[i + 1].y) {
                self.nodes[i].width += self.nodes[i + 1].width;
                self.removeNode(i + 1);
                // don't increment — check merged node against next
            } else {
                i += 1;
            }
        }
    }
};
