//! Graceful reload functionality for zero-downtime configuration updates
//! Handles SIGHUP/SIGUSR2 signals to reload configuration without dropping connections

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

/// Graceful reload manager
pub const GracefulReload = struct {
    allocator: std.mem.Allocator,

    /// Current configuration
    current_config: config.Config,

    /// Signal handling
    signal_channel: SignalChannel,

    /// Reload callback
    reload_callback: ?*const fn (*config.Config) anyerror!void,

    /// Whether reload is in progress
    reloading: bool = false,

    const SignalChannel = struct {
        /// Pipe for signal communication (read end)
        read_fd: std.posix.fd_t,

        /// Pipe for signal communication (write end)
        write_fd: std.posix.fd_t,
    };

    /// Initialize graceful reload manager
    pub fn init(allocator: std.mem.Allocator, initial_config: config.Config) !GracefulReload {
        // Create signal pipe
        const pipe_fds = try std.posix.pipe2(.{ .CLOEXEC = true });

        const gr = GracefulReload{
            .allocator = allocator,
            .current_config = initial_config,
            .signal_channel = SignalChannel{
                .read_fd = pipe_fds[0],
                .write_fd = pipe_fds[1],
            },
            .reload_callback = null,
        };

        // Set up signal handlers (Linux only for now)
        if (builtin.os.tag == .linux) {
            try setupSignalHandlers(gr.signal_channel.write_fd);
        }

        return gr;
    }

    /// Deinitialize graceful reload manager
    pub fn deinit(self: *GracefulReload) void {
        self.current_config.deinit();

        std.posix.close(self.signal_channel.read_fd);
        std.posix.close(self.signal_channel.write_fd);
    }

    /// Set the reload callback function
    pub fn setReloadCallback(self: *GracefulReload, callback: *const fn (*config.Config) anyerror!void) void {
        self.reload_callback = callback;
    }

    /// Check if a reload signal has been received
    pub fn checkForReloadSignal(self: *GracefulReload) !?ReloadRequest {
        // Non-blocking read from signal pipe
        var buf: [1]u8 = undefined;
        const bytes_read = std.posix.read(self.signal_channel.read_fd, &buf) catch |err| {
            if (err == error.WouldBlock) {
                return null; // No signal received
            }
            return err;
        };

        if (bytes_read == 1) {
            const signal_type = @as(SignalType, @enumFromInt(buf[0]));
            return ReloadRequest{ .signal = signal_type };
        }

        return null;
    }

    /// Perform a configuration reload
    pub fn performReload(self: *GracefulReload, config_path: []const u8) !void {
        if (self.reloading) {
            std.log.warn("Reload already in progress, ignoring", .{});
            return;
        }

        self.reloading = true;
        defer self.reloading = false;

        std.log.info("Starting configuration reload from {s}", .{config_path});

        // Load new configuration
        var new_config = try config.loadConfig(self.allocator, config_path);
        errdefer new_config.deinit();

        // Validate new configuration
        try new_config.validate();

        std.log.info("New configuration loaded and validated", .{});

        // Call reload callback if set
        if (self.reload_callback) |callback| {
            try callback(&new_config);
        }

        // Replace old configuration
        self.current_config.deinit();
        self.current_config = new_config;

        std.log.info("Configuration reload completed successfully", .{});
    }

    /// Get current configuration (read-only)
    pub fn getCurrentConfig(self: *const GracefulReload) *const config.Config {
        return &self.current_config;
    }

    /// Setup signal handlers (Linux only)
    fn setupSignalHandlers(write_fd: std.posix.fd_t) !void {
        // Set up SIGHUP handler (configuration reload)
        const sighup_handler = struct {
            fn handler(sig: c_int) callconv(.c) void {
                _ = sig;
                // Write signal type to pipe
                const signal_byte = @intFromEnum(SignalType.sighup);
                _ = std.posix.write(write_fd, &[_]u8{signal_byte}) catch {};
            }
        }.handler;

        // Set up SIGUSR2 handler (alternative reload signal)
        const sigusr2_handler = struct {
            fn handler(sig: c_int) callconv(.c) void {
                _ = sig;
                // Write signal type to pipe
                const signal_byte = @intFromEnum(SignalType.sigusr2);
                _ = std.posix.write(write_fd, &[_]u8{signal_byte}) catch {};
            }
        }.handler;

        var act = std.posix.Sigaction{
            .handler = .{ .sigaction = sighup_handler },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };

        // Register SIGHUP
        std.posix.sigaction(std.posix.SIG.HUP, &act, null);

        // Register SIGUSR2
        act.handler = .{ .sigaction = sigusr2_handler };
        std.posix.sigaction(std.posix.SIG.USR2, &act, null);

        std.log.info("Signal handlers registered for graceful reload (SIGHUP, SIGUSR2)", .{});
    }
};

/// Reload request information
pub const ReloadRequest = struct {
    signal: SignalType,
    timestamp: i64 = std.time.milliTimestamp(),
};

/// Signal types that trigger reload
pub const SignalType = enum(u8) {
    sighup = 1, // Standard configuration reload signal
    sigusr2 = 2, // Alternative reload signal (Nginx style)
};

/// Graceful reload error types
pub const GracefulReloadError = error{
    PipeCreationFailed,
    SignalSetupFailed,
    ReloadInProgress,
    ConfigLoadFailed,
    ConfigValidationFailed,
    CallbackFailed,
};

// Export types for external use
pub const ReloadError = GracefulReloadError;
