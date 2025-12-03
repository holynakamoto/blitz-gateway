//! Graceful reload functionality for zero-downtime configuration updates
//! Handles SIGHUP/SIGUSR2 signals to reload configuration without dropping connections
//!
//! Multiple GracefulReload instances can coexist safely. When a signal is received,
//! all registered instances will be notified via their respective signal pipes.
//! Each instance maintains its own configuration and reload callback.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config/mod.zig");

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
    reloading: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
    /// Unregisters this instance's write_fd from the global registry before closing it
    pub fn deinit(self: *GracefulReload) void {
        self.current_config.deinit();

        // Unregister before closing to avoid writing to a closed fd
        unregisterWriteFd(self.signal_channel.write_fd);

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
            // Validate the byte value before converting to enum to avoid undefined behavior
            const signal_type = switch (buf[0]) {
                1 => SignalType.sighup,
                2 => SignalType.sigusr2,
                else => {
                    std.log.warn("Invalid signal byte received: {d}, ignoring", .{buf[0]});
                    return null; // Treat invalid signal as no signal
                },
            };
            return ReloadRequest{ .signal = signal_type };
        }

        return null;
    }

    /// Perform a configuration reload
    pub fn performReload(self: *GracefulReload, config_path: []const u8) !void {
        if (self.reloading.load(.Acquire)) {
            std.log.warn("Reload already in progress, ignoring", .{});
            return;
        }

        // Atomically transition from false to true
        if (self.reloading.compareExchange(false, true, .Strong, .Acquire) != null) {
            std.log.warn("Reload already in progress, ignoring", .{});
            return;
        }
        defer self.reloading.store(false, .Release);

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

    /// Thread-safe registry for write_fds from all GracefulReload instances
    /// This allows multiple instances to coexist and all receive signal notifications
    /// Uses a mutex for registration/unregistration, but signal handlers read lock-free
    /// Uses a fixed-size array to ensure async-signal-safe reads in signal handlers
    const WriteFdRegistry = struct {
        mutex: std.Thread.Mutex = .{},
        // Fixed-size array for async-signal-safe lock-free reads
        // Maximum of 64 instances should be sufficient for most use cases
        fds: [64]std.posix.fd_t = [_]std.posix.fd_t{-1} ** 64,
        // Atomic count for lock-free reads in signal handlers
        count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        // Atomic version counter for lock-free reads in signal handlers
        version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        fn init() WriteFdRegistry {
            return .{};
        }

        fn deinit(_: *WriteFdRegistry) void {
            // No cleanup needed for fixed-size array
        }

        /// Register a write_fd to receive signal notifications
        /// Thread-safe: can be called concurrently from multiple instances
        /// Returns error if registry is full (max 64 instances)
        fn register(self: *WriteFdRegistry, write_fd: std.posix.fd_t) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const current_count = self.count.load(.Acquire);
            if (current_count >= self.fds.len) {
                return error.RegistryFull;
            }
            self.fds[current_count] = write_fd;
            _ = self.count.fetchAdd(1, .Release);
            _ = self.version.fetchAdd(1, .Release);
        }

        /// Unregister a write_fd from signal notifications
        /// Thread-safe: can be called concurrently from multiple instances
        fn unregister(self: *WriteFdRegistry, write_fd: std.posix.fd_t) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const current_count = self.count.load(.Acquire);
            // Remove the fd from the array (linear search is fine for small arrays)
            for (0..current_count) |i| {
                if (self.fds[i] == write_fd) {
                    // Swap with last element and decrement count
                    if (i < current_count - 1) {
                        self.fds[i] = self.fds[current_count - 1];
                    }
                    self.fds[current_count - 1] = -1;
                    _ = self.count.fetchSub(1, .Release);
                    _ = self.version.fetchAdd(1, .Release);
                    break;
                }
            }
        }

        /// Get fds for signal handler iteration (lock-free, async-signal-safe)
        /// Returns the count and a pointer to the fixed array
        /// Safe because we read atomic count and fixed array pointer
        fn getFdsForSignalHandler(self: *WriteFdRegistry) struct { fds: []const std.posix.fd_t, count: usize, version: u64 } {
            // Lock-free read: get current version, count, and array pointer
            // Reading count and array pointer is safe because:
            // - count is atomic, can be read lock-free
            // - array is fixed-size, so pointer never changes
            // - we may read slightly stale count, but that's acceptable (we handle write errors)
            const current_version = self.version.load(.Acquire);
            const current_count = self.count.load(.Acquire);
            return .{
                .fds = self.fds[0..current_count],
                .count = current_count,
                .version = current_version,
            };
        }
    };

    /// Global registry for all GracefulReload instance write_fds
    /// Initialized on first use, persists for the lifetime of the process
    var registry: ?WriteFdRegistry = null;
    var registry_init_mutex: std.Thread.Mutex = .{};

    /// Initialize the global registry (thread-safe, idempotent)
    fn ensureRegistry() !*WriteFdRegistry {
        registry_init_mutex.lock();
        defer registry_init_mutex.unlock();

        if (registry) |*r| {
            return r;
        }

        // Registry uses fixed-size array, no allocator needed
        registry = WriteFdRegistry.init();
        return &registry.?;
    }

    /// Register this instance's write_fd with the global registry
    fn registerWriteFd(write_fd: std.posix.fd_t) !void {
        const reg = try ensureRegistry();
        try reg.register(write_fd);
    }

    /// Unregister this instance's write_fd from the global registry
    fn unregisterWriteFd(write_fd: std.posix.fd_t) void {
        if (registry) |*reg| {
            reg.unregister(write_fd);
        }
    }

    /// Setup signal handlers (Linux only)
    /// Signal handlers will write to all registered write_fds
    fn setupSignalHandlers(write_fd: std.posix.fd_t) !void {
        // Register this instance's write_fd
        try registerWriteFd(write_fd);

        // Set up signal handlers only once (they're process-wide)
        // Use a static flag to ensure handlers are only registered once
        const HandlerSetup = struct {
            var initialized: bool = false;
            var init_mutex: std.Thread.Mutex = .{};
        };

        HandlerSetup.init_mutex.lock();
        defer HandlerSetup.init_mutex.unlock();

        if (HandlerSetup.initialized) {
            return; // Handlers already set up
        }
        HandlerSetup.initialized = true;

        // Set up SIGHUP handler (configuration reload)
        // sigaction expects: fn (i32, *const os.linux.siginfo_t, ?*anyopaque) callconv(.c) void
        // The handler writes to all registered write_fds so all GracefulReload instances receive the signal
        const sighup_handler = struct {
            fn handler(sig: i32, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
                _ = sig;
                writeToAllRegisteredFds(SignalType.sighup);
            }
        }.handler;

        // Set up SIGUSR2 handler (alternative reload signal)
        // The handler writes to all registered write_fds so all GracefulReload instances receive the signal
        const sigusr2_handler = struct {
            fn handler(sig: i32, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
                _ = sig;
                writeToAllRegisteredFds(SignalType.sigusr2);
            }
        }.handler;

        // Create empty sigset (Zig 0.15.2 API - returns sigset_t, doesn't take arguments)
        const empty_mask = std.posix.sigemptyset();

        var act = std.posix.Sigaction{
            .handler = .{ .sigaction = sighup_handler },
            .mask = empty_mask,
            .flags = 0,
        };

        // Register SIGHUP (sigaction returns void in Zig 0.15.2)
        std.posix.sigaction(std.posix.SIG.HUP, &act, null);

        // Register SIGUSR2
        act.handler = .{ .sigaction = sigusr2_handler };
        std.posix.sigaction(std.posix.SIG.USR2, &act, null);

        std.log.info("Signal handlers registered for graceful reload (SIGHUP, SIGUSR2)", .{});
    }

    /// Write signal to all registered write_fds
    /// This function is called from signal handlers and must be async-signal-safe
    /// Uses lock-free reads to avoid mutex usage in signal context
    fn writeToAllRegisteredFds(signal_type: SignalType) void {
        // Signal handlers must be async-signal-safe, so we can't use the mutex
        // Instead, we read the array pointer and length lock-free (best effort)
        // If registry is null or empty, this is a no-op
        if (registry) |*reg| {
            // Lock-free read: get count and pointer to fixed array
            // Reading count and array is safe because:
            // - count is atomically read
            // - array is fixed-size, pointer never changes
            // - we may read stale count, but that's acceptable - we handle write errors
            const snapshot = reg.getFdsForSignalHandler();

            const signal_byte = @intFromEnum(signal_type);
            const signal_buf = [_]u8{signal_byte};

            // Write to all registered fds
            // Array is fixed-size so pointer is stable, count may be slightly stale
            for (snapshot.fds) |fd| {
                if (fd != -1) {
                    _ = std.posix.write(fd, &signal_buf) catch {
                        // Ignore write errors (fd may be closed, pipe full, etc.)
                        // This is expected behavior in signal handlers
                    };
                }
            }
        }
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
    RegistryFull, // Too many GracefulReload instances (max 64)
};

// Export types for external use
pub const ReloadError = GracefulReloadError;
