// QUIC Frame Type Definitions (RFC 9000 Section 19)

const constants = @import("../constants.zig");
const types = @import("../types.zig");

// Frame type enum
pub const FrameType = enum(u8) {
    padding = constants.FRAME_TYPE_PADDING,
    ping = constants.FRAME_TYPE_PING,
    ack = constants.FRAME_TYPE_ACK,
    ack_ecn = constants.FRAME_TYPE_ACK_ECN,
    reset_stream = constants.FRAME_TYPE_RESET_STREAM,
    stop_sending = constants.FRAME_TYPE_STOP_SENDING,
    crypto = constants.FRAME_TYPE_CRYPTO,
    new_token = constants.FRAME_TYPE_NEW_TOKEN,
    stream = constants.FRAME_TYPE_STREAM,
    max_data = constants.FRAME_TYPE_MAX_DATA,
    max_stream_data = constants.FRAME_TYPE_MAX_STREAM_DATA,
    max_streams = constants.FRAME_TYPE_MAX_STREAMS,
    data_blocked = constants.FRAME_TYPE_DATA_BLOCKED,
    stream_data_blocked = constants.FRAME_TYPE_STREAM_DATA_BLOCKED,
    streams_blocked = constants.FRAME_TYPE_STREAMS_BLOCKED,
    new_connection_id = constants.FRAME_TYPE_NEW_CONNECTION_ID,
    retire_connection_id = constants.FRAME_TYPE_RETIRE_CONNECTION_ID,
    path_challenge = constants.FRAME_TYPE_PATH_CHALLENGE,
    path_response = constants.FRAME_TYPE_PATH_RESPONSE,
    connection_close = constants.FRAME_TYPE_CONNECTION_CLOSE,
    connection_close_app = constants.FRAME_TYPE_CONNECTION_CLOSE_APP,
    handshake_done = constants.FRAME_TYPE_HANDSHAKE_DONE,
};

// Base frame trait
pub const Frame = union(FrameType) {
    padding: void,
    ping: void,
    ack: AckFrame,
    ack_ecn: AckEcnFrame,
    reset_stream: ResetStreamFrame,
    stop_sending: StopSendingFrame,
    crypto: CryptoFrame,
    new_token: NewTokenFrame,
    stream: StreamFrame,
    max_data: MaxDataFrame,
    max_stream_data: MaxStreamDataFrame,
    max_streams: MaxStreamsFrame,
    data_blocked: DataBlockedFrame,
    stream_data_blocked: StreamDataBlockedFrame,
    streams_blocked: StreamsBlockedFrame,
    new_connection_id: NewConnectionIdFrame,
    retire_connection_id: RetireConnectionIdFrame,
    path_challenge: PathChallengeFrame,
    path_response: PathResponseFrame,
    connection_close: ConnectionCloseFrame,
    connection_close_app: ConnectionCloseAppFrame,
    handshake_done: void,

    // Frame structures
    pub const AckFrame = struct {
        largest_acked: types.PacketNumber,
        ack_delay: u64,
        ack_range_count: u64,
        first_ack_range: u64,
        ack_ranges: []AckRange,
    };

    pub const AckRange = struct {
        gap: u64,
        ack_range_length: u64,
    };

    pub const AckEcnFrame = struct {
        // Same as AckFrame plus ECN counts
        largest_acked: types.PacketNumber,
        ack_delay: u64,
        ack_range_count: u64,
        first_ack_range: u64,
        ack_ranges: []AckRange,
        ect0_count: u64,
        ect1_count: u64,
        ecn_ce_count: u64,
    };

    pub const ResetStreamFrame = struct {
        stream_id: types.StreamId,
        error_code: types.ErrorCode,
        final_size: u64,
    };

    pub const StopSendingFrame = struct {
        stream_id: types.StreamId,
        error_code: types.ErrorCode,
    };

    pub const CryptoFrame = struct {
        offset: u64,
        length: u64,
        data: []const u8,
    };

    pub const NewTokenFrame = struct {
        token: []const u8,
    };

    pub const StreamFrame = struct {
        stream_id: types.StreamId,
        offset: u64,
        length: u64,
        fin: bool,
        data: []const u8,
    };

    pub const MaxDataFrame = struct {
        maximum_data: u64,
    };

    pub const MaxStreamDataFrame = struct {
        stream_id: types.StreamId,
        maximum_stream_data: u64,
    };

    pub const MaxStreamsFrame = struct {
        stream_type: StreamType,
        maximum_streams: u64,
    };

    pub const StreamType = enum {
        bidirectional,
        unidirectional,
    };

    pub const DataBlockedFrame = struct {
        data_limit: u64,
    };

    pub const StreamDataBlockedFrame = struct {
        stream_id: types.StreamId,
        stream_data_limit: u64,
    };

    pub const StreamsBlockedFrame = struct {
        stream_type: StreamType,
        stream_limit: u64,
    };

    pub const NewConnectionIdFrame = struct {
        sequence: u64,
        retire_prior_to: u64,
        connection_id: types.ConnectionId,
        stateless_reset_token: [16]u8,
    };

    pub const RetireConnectionIdFrame = struct {
        sequence: u64,
    };

    pub const PathChallengeFrame = struct {
        data: [8]u8,
    };

    pub const PathResponseFrame = struct {
        data: [8]u8,
    };

    pub const ConnectionCloseFrame = struct {
        error_code: types.ErrorCode,
        frame_type: ?u64,
        reason_phrase_length: u64,
        reason_phrase: []const u8,
    };

    pub const ConnectionCloseAppFrame = struct {
        error_code: types.ErrorCode,
        reason_phrase_length: u64,
        reason_phrase: []const u8,
    };
};

