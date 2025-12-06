// PADDING Frame (RFC 9000 Section 19.1)
// Used to increase packet size

const constants = @import("../constants.zig");

pub const PaddingFrame = struct {
    length: usize, // Number of padding bytes

    pub fn write(self: PaddingFrame, writer: anytype) !usize {
        for (0..self.length) |_| {
            try writer.writeByte(constants.FRAME_TYPE_PADDING);
        }
        return self.length;
    }
};

