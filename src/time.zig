const std = @import("std");
const sdl = @import("zsdl");

var freqMs: u64 = 0;
var lastTime: u64 = 0;

var frameCounter: u64 = 0;
var frameTimer: u64 = 0;

var fps: u64 = 0;

var currentTime: u64 = 0;

pub var alpha: f64 = 0;
pub var accumulator: f64 = 0;
var frameTime: f64 = 0;

pub fn init() void {
    freqMs = sdl.getPerformanceFrequency();
    lastTime = sdl.getPerformanceCounter();
}

pub fn frameBegin() void {
    currentTime = sdl.getPerformanceCounter();
    frameTime = (@as(f64, @floatFromInt(currentTime - lastTime))) / @as(f64, @floatFromInt(freqMs));
    if (frameTime > 0.25) {
        frameTime = 0.25;
    }
    accumulator += frameTime;
}

pub fn frameEnd() void {
    lastTime = currentTime;
    frameCounter += 1;
}

pub fn calculateFps() u64 {
    if (currentTime > frameTimer + freqMs) {
        fps = frameCounter;
        frameCounter = 0;
        frameTimer = currentTime;
    }
    return fps;
}
