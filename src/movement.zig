const data = @import("data.zig");

pub const GroundState = struct {
    contactCount: usize = 0,
    supported: bool = false,
    jumpAvailable: bool = false,
    supportLostAtMs: ?u64 = null,
};

pub var mechanism: data.MovementMechanism = undefined;
pub var control: data.MovementControlData = undefined;
pub var bodyMotion: data.MovementBodyMotionData = undefined;
pub var surfaceResponse: data.MovementSurfaceResponseData = undefined;
pub var jump: data.MovementJumpData = undefined;
pub var grounding: data.MovementGroundingData = undefined;

pub fn configure(movementData: data.MovementData) void {
    mechanism = movementData.mechanism;
    control = movementData.control;
    bodyMotion = movementData.bodyMotion;
    surfaceResponse = movementData.surfaceResponse;
    jump = movementData.jump;
    grounding = movementData.grounding;
}
