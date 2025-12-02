//! QUIC Protocol Implementation
//! Public API for QUIC connection handling, packet processing, and handshake

// Public types and constants
pub const QuicServerConnection = @import("server.zig").QuicServerConnection;
pub const QuicServer = @import("server.zig").QuicServer;

pub const QuicConnection = @import("connection.zig").QuicConnection;
pub const ConnectionState = @import("connection.zig").ConnectionState;
pub const Stream = @import("connection.zig").Stream;
pub const StreamState = @import("connection.zig").StreamState;

pub const QuicHandshake = @import("handshake.zig").QuicHandshake;
pub const HandshakeState = @import("handshake.zig").HandshakeState;

pub const Packet = @import("packet.zig").Packet;
pub const LongHeaderPacket = @import("packet.zig").LongHeaderPacket;
pub const ShortHeaderPacket = @import("packet.zig").ShortHeaderPacket;
pub const QUIC_VERSION_1 = @import("packet.zig").QUIC_VERSION_1;

pub const CryptoFrame = @import("frames.zig").CryptoFrame;
pub const FrameType = @import("frames.zig").FrameType;

pub const InitialSecrets = @import("crypto.zig").InitialSecrets;
pub const ZeroRttSecrets = @import("crypto.zig").ZeroRttSecrets;
pub const deriveInitialSecrets = @import("crypto.zig").deriveInitialSecrets;
pub const decryptPayload = @import("crypto.zig").decryptPayload;
pub const encryptPayload = @import("crypto.zig").encryptPayload;

pub const TransportParameters = @import("transport_params.zig").TransportParameters;
pub const TransportParameterId = @import("transport_params.zig").TransportParameterId;

// UDP utilities
pub const createUdpSocket = @import("udp.zig").createUdpSocket;
pub const UdpConnection = @import("udp.zig").UdpConnection;
pub const prepRecvFrom = @import("udp.zig").prepRecvFrom;
pub const prepSendTo = @import("udp.zig").prepSendTo;

// UDP server
pub const UdpBufferPool = @import("udp_server.zig").UdpBufferPool;
pub const runQuicServer = @import("udp_server.zig").runQuicServer;

// PicoTLS integration
pub const TlsContext = @import("picotls.zig").TlsContext;
pub const EncryptionLevel = @import("picotls.zig").EncryptionLevel;
pub const HandshakeOutput = @import("picotls.zig").HandshakeOutput;

