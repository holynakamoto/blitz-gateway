//! Load Balancer Module
//! Public API for load balancing, backend management, health checks, and connection pooling

pub const LoadBalancer = @import("load_balancer.zig").LoadBalancer;
pub const LoadBalancerError = @import("load_balancer.zig").LoadBalancerError;
pub const ForwardResult = @import("load_balancer.zig").ForwardResult;

pub const Backend = @import("backend.zig").Backend;
pub const BackendPool = @import("backend.zig").BackendPool;

pub const HealthChecker = @import("health_check.zig").HealthChecker;

pub const BackendConnection = @import("connection_pool.zig").BackendConnection;
pub const ConnectionPool = @import("connection_pool.zig").ConnectionPool;
