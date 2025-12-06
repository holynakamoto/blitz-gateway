// quic/constants.zig
// All magic numbers from RFC 9000, 9001, 9002, 9114 — frozen forever

pub const VERSION_1 = 0x00000001;
pub const VERSION_DRAFT_29 = 0xff00001d; // for interop with old clients
pub const VERSION_NEGOTIATION = 0x0a0a0a0a; // grease

// RFC 9001 — Initial salt for version 1
pub const INITIAL_SALT: [20]u8 = .{
    0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x39, 0x69, 0x3b, 0x56, 0x1c, 0x66, 0x61, 0x4b, 0x1f, 0x58, 0x3c, 0x4e, 0x53, 0x54, 0x1c,
};

// Packet types (long header)
pub const PACKET_TYPE_INITIAL = 0x0;
pub const PACKET_TYPE_0RTT = 0x1;
pub const PACKET_TYPE_HANDSHAKE = 0x2;
pub const PACKET_TYPE_RETRY = 0x3;

// Frame types
pub const FRAME_PADDING = 0x00;
pub const FRAME_PING = 0x01;
pub const FRAME_ACK = 0x02;
pub const FRAME_ACK_ECN = 0x03;
pub const FRAME_CRYPTO = 0x06;
pub const FRAME_NEW_CONNECTION_ID = 0x07;
pub const FRAME_STREAM = 0x08;
pub const FRAME_STREAM_FIN = 0x09;
pub const FRAME_STREAM_LEN = 0x0a;
pub const FRAME_STREAM_FIN_LEN = 0x0b;
pub const FRAME_STREAM_OFF = 0x0c;
pub const FRAME_STREAM_OFF_FIN = 0x0d;
pub const FRAME_STREAM_OFF_LEN = 0x0e;
pub const FRAME_STREAM_OFF_FIN_LEN = 0x0f;
pub const FRAME_MAX_DATA = 0x10;
pub const FRAME_MAX_STREAM_DATA = 0x11;
pub const FRAME_MAX_STREAMS_BIDI = 0x12;
pub const FRAME_MAX_STREAMS_UNI = 0x13;
pub const FRAME_DATA_BLOCKED = 0x14;
pub const FRAME_STREAM_DATA_BLOCKED = 0x15;
pub const FRAME_STREAMS_BLOCKED_BIDI = 0x16;
pub const FRAME_STREAMS_BLOCKED_UNI = 0x17;
pub const FRAME_NEW_TOKEN = 0x18;
pub const FRAME_STOP_SENDING = 0x19;
pub const FRAME_RETIRE_CONNECTION_ID = 0x1a;
pub const FRAME_PATH_CHALLENGE = 0x1b;
pub const FRAME_PATH_RESPONSE = 0x1c;
pub const FRAME_CONNECTION_CLOSE = 0x1d;
pub const FRAME_CONNECTION_CLOSE_APP = 0x1e;
pub const FRAME_HANDSHAKE_DONE = 0x1f;

// Transport error codes (RFC 9000 §20.1)
pub const NO_ERROR = 0x0;
pub const INTERNAL_ERROR = 0x1;
pub const CONNECTION_REFUSED = 0x2;
pub const FLOW_CONTROL_ERROR = 0x3;
pub const STREAM_LIMIT_ERROR = 0x4;
pub const STREAM_STATE_ERROR = 0x5;
pub const FINAL_SIZE_ERROR = 0x6;
pub const FRAME_ENCODING_ERROR = 0x7;
pub const TRANSPORT_PARAMETER_ERROR = 0x8;
pub const CONNECTION_ID_LIMIT_ERROR = 0x9;
pub const PROTOCOL_VIOLATION = 0xa;
pub const INVALID_TOKEN = 0xb;
pub const APPLICATION_ERROR = 0xc;
pub const CRYPTO_ERROR_BASE = 0x100;
pub const CRYPTO_ERROR_MASK = 0x1ff;

// Crypto error codes (TLS alerts → QUIC)
pub const TLS_ALERT_CLOSE_NOTIFY = 0x00;
pub const TLS_ALERT_UNEXPECTED_MESSAGE = 0x0a;
pub const TLS_ALERT_BAD_CERTIFICATE = 0x2a;
pub const TLS_ALERT_INTERNAL_ERROR = 0x50;

// Limits
pub const MAX_CID_LEN = 20;
pub const MIN_INITIAL_PACKET_SIZE = 1200;
pub const MAX_UDP_PAYLOAD_SIZE = 65527;
pub const ACK_DELAY_EXPONENT_DEFAULT = 3;
pub const MAX_ACK_DELAY = 1 << 14; // 2^14 ms
