// C Translation Unit for io_uring and system headers
// This file centralizes C imports to avoid issues with @cDefine and @cInclude

// Define AT_FDCWD if not already defined (needed for liburing.h on some systems)
const AT_FDCWD: c_int = -100;

pub const c = @cImport({
    @cDefine("AT_FDCWD", "-100");
    @cInclude("liburing.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
});

