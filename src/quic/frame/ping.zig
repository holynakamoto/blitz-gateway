// PING Frame (RFC 9000 Section 19.2)
// Used to keep connection alive or verify peer reachability

const constants = @import("../constants.zig");

pub const PingFrame = struct {
    pub fn write(writer: anytype) !usize {
        try writer.writeByte(constants.FRAME_TYPE_PING);
        return 1;
    }
};

