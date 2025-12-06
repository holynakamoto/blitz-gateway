// Frame Writer (RFC 9000 Section 19)
// Frame serialization

const std = @import("std");
const constants = @import("../constants.zig");
const varint = @import("../varint.zig");
const Frame = @import("types.zig").Frame;

/// Write frames to a buffer
pub fn writeFrames(writer: anytype, frames: []const Frame) !usize {
    var total_written: usize = 0;

    for (frames) |frame| {
        total_written += try writeFrame(writer, frame);
    }

    return total_written;
}

/// Write a single frame to a writer
fn writeFrame(writer: anytype, frame: Frame) !usize {
    return switch (frame) {
        .padding => {
            try writer.writeByte(constants.FRAME_TYPE_PADDING);
            return 1;
        },
        .ping => {
            try writer.writeByte(constants.FRAME_TYPE_PING);
            return 1;
        },
        .crypto => |crypto| {
            return crypto.write(writer);
        },
        else => {
            // TODO: Implement all frame types
            return error.UnsupportedFrameType;
        },
    };
}

