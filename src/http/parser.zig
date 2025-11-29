const std = @import("std");

// HTTP/1.1 Request Parser
// Zero-allocation parser that works on pre-allocated buffers
// Optimized for speed - no heap allocations, SIMD-ready structure

// Request validation limits (DoS protection)
const MAX_REQUEST_SIZE: usize = 16 * 1024; // 16KB max request size
const MAX_HEADERS: usize = 100; // Max 100 headers
const MAX_PATH_LENGTH: usize = 8192; // 8KB max path length
const MAX_HEADER_NAME_LENGTH: usize = 256; // Max header name length
const MAX_HEADER_VALUE_LENGTH: usize = 8192; // Max header value length

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    CONNECT,
    TRACE,
    UNKNOWN,
};

pub const Version = enum {
    HTTP_1_0,
    HTTP_1_1,
    HTTP_2_0,
    UNKNOWN,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    version: Version,
    headers: []Header,
    body: []const u8,
    raw: []const u8, // Original request buffer

    pub fn getHeader(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return header.value;
            }
        }
        return null;
    }
};

// Parse HTTP/1.1 request from buffer
// Returns parsed request or error
// Zero-allocation: all slices point into the input buffer
pub fn parseRequest(buffer: []const u8) !Request {
    // Validate request size (DoS protection)
    if (buffer.len > MAX_REQUEST_SIZE) {
        return error.RequestTooLarge;
    }
    
    if (buffer.len == 0) {
        return error.EmptyRequest;
    }

    var request = Request{
        .method = .UNKNOWN,
        .path = "",
        .version = .UNKNOWN,
        .headers = &[_]Header{},
        .body = "",
        .raw = buffer,
    };

    var pos: usize = 0;
    const len = buffer.len;

    // Parse request line: "METHOD /path HTTP/1.1\r\n"
    const request_line_end = std.mem.indexOf(u8, buffer, "\r\n") orelse return error.InvalidRequestLine;
    const request_line = buffer[0..request_line_end];
    pos = request_line_end + 2;

    // Parse method
    const method_end = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.InvalidRequestLine;
    const method_str = request_line[0..method_end];
    request.method = parseMethod(method_str);

    // Parse path (strip query string if present)
    const path_start = method_end + 1;
    const path_end = std.mem.indexOfScalarPos(u8, request_line, path_start, ' ') orelse return error.InvalidRequestLine;
    const full_path = request_line[path_start..path_end];
    
    // Validate path length (DoS protection)
    if (full_path.len > MAX_PATH_LENGTH) {
        return error.PathTooLong;
    }
    
    // Strip query string (everything after '?')
    const query_start = std.mem.indexOfScalar(u8, full_path, '?');
    request.path = if (query_start) |qs| full_path[0..qs] else full_path;

    // Parse version
    const version_start = path_end + 1;
    const version_str = request_line[version_start..];
    request.version = parseVersion(version_str);

    // Parse headers
    var header_count: usize = 0;
    var headers: [MAX_HEADERS]Header = undefined;

    while (pos < len) {
        // Check for end of headers (empty line)
        if (pos + 1 < len and buffer[pos] == '\r' and buffer[pos + 1] == '\n') {
            pos += 2;
            break;
        }

        // Find end of header line
        const header_line_end = std.mem.indexOfPos(u8, buffer, pos, "\r\n") orelse break;
        const header_line = buffer[pos..header_line_end];
        pos = header_line_end + 2;

        // Parse header: "Name: Value"
        const colon_pos = std.mem.indexOfScalar(u8, header_line, ':') orelse continue;
        const name = std.mem.trim(u8, header_line[0..colon_pos], " \t");
        const value_start = colon_pos + 1;
        const value = std.mem.trim(u8, header_line[value_start..], " \t");

        // Validate header name and value lengths (DoS protection)
        if (name.len > MAX_HEADER_NAME_LENGTH) {
            return error.HeaderNameTooLong;
        }
        if (value.len > MAX_HEADER_VALUE_LENGTH) {
            return error.HeaderValueTooLong;
        }

        if (header_count < MAX_HEADERS) {
            headers[header_count] = Header{
                .name = name,
                .value = value,
            };
            header_count += 1;
        } else {
            // Too many headers
            return error.TooManyHeaders;
        }
    }

    request.headers = headers[0..header_count];

    // Parse body (if present)
    if (pos < len) {
        request.body = buffer[pos..];
    }

    return request;
}

fn parseMethod(method_str: []const u8) Method {
    if (std.mem.eql(u8, method_str, "GET")) return .GET;
    if (std.mem.eql(u8, method_str, "POST")) return .POST;
    if (std.mem.eql(u8, method_str, "PUT")) return .PUT;
    if (std.mem.eql(u8, method_str, "DELETE")) return .DELETE;
    if (std.mem.eql(u8, method_str, "PATCH")) return .PATCH;
    if (std.mem.eql(u8, method_str, "HEAD")) return .HEAD;
    if (std.mem.eql(u8, method_str, "OPTIONS")) return .OPTIONS;
    if (std.mem.eql(u8, method_str, "CONNECT")) return .CONNECT;
    if (std.mem.eql(u8, method_str, "TRACE")) return .TRACE;
    return .UNKNOWN;
}

fn parseVersion(version_str: []const u8) Version {
    if (std.mem.eql(u8, version_str, "HTTP/1.0")) return .HTTP_1_0;
    if (std.mem.eql(u8, version_str, "HTTP/1.1")) return .HTTP_1_1;
    if (std.mem.eql(u8, version_str, "HTTP/2.0")) return .HTTP_2_0;
    return .UNKNOWN;
}

// Format HTTP response (zero-allocation, uses provided buffer)
pub fn formatResponse(buffer: []u8, status_code: u16, status_text: []const u8, headers: []const Header, body: []const u8) ![]u8 {
    var pos: usize = 0;

    // Status line: "HTTP/1.1 200 OK\r\n"
    const status_line = try std.fmt.bufPrint(buffer[pos..], "HTTP/1.1 {} {s}\r\n", .{ status_code, status_text });
    pos += status_line.len;

    // Headers
    for (headers) |header| {
        const header_line = try std.fmt.bufPrint(buffer[pos..], "{s}: {s}\r\n", .{ header.name, header.value });
        pos += header_line.len;
    }

    // Content-Length header if body present
    if (body.len > 0) {
        const content_length = try std.fmt.bufPrint(buffer[pos..], "Content-Length: {}\r\n", .{body.len});
        pos += content_length.len;
    }

    // Connection header
    const connection = try std.fmt.bufPrint(buffer[pos..], "Connection: keep-alive\r\n", .{});
    pos += connection.len;

    // Empty line before body
    buffer[pos] = '\r';
    buffer[pos + 1] = '\n';
    pos += 2;

    // Body
    if (body.len > 0) {
        if (pos + body.len > buffer.len) {
            return error.BufferTooSmall;
        }
        @memcpy(buffer[pos..][0..body.len], body);
        pos += body.len;
    }

    return buffer[0..pos];
}

// Pre-formatted common responses (zero-allocation)
pub const CommonResponses = struct {
    // Optimized for benchmarking - minimal response
    pub const HELLO = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, Blitz!";
    pub const OK = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nHello, Blitz!";
    pub const NOT_FOUND = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n";
    pub const BAD_REQUEST = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n";
    pub const INTERNAL_ERROR = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n";
    pub const METHOD_NOT_ALLOWED = "HTTP/1.1 405 Method Not Allowed\r\nContent-Type: text/plain\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n";
};

