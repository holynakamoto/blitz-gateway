//! HTTP/2 Module
//! Public API for HTTP/2 frame handling and connection management

pub const Http2Connection = @import("connection.zig").Http2Connection;
pub const Frame = @import("frame.zig").Frame;
pub const FrameType = @import("frame.zig").FrameType;
pub const Hpack = @import("hpack.zig");

