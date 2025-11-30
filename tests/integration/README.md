# Load Balancer Module

Complete load balancing implementation for Blitz Gateway with backend pool management, health checks, connection pooling, retry logic, and timeout handling.

## Features

### ✅ Implemented

1. **Backend Pool** (`backend.zig`)
   - Manage multiple backend servers
   - Track backend health status
   - Record statistics (requests, successes, failures)
   - Weight support (for future weighted algorithms)

2. **Round Robin** (`backend.zig`)
   - Simple round-robin selection algorithm
   - Skips unhealthy backends automatically
   - Falls back to unhealthy backends if all are down

3. **Health Checks** (`health_check.zig`)
   - Periodic health monitoring
   - HTTP health check endpoint support
   - Configurable health check interval and timeout
   - Automatic unhealthy backend detection (3 consecutive failures)

4. **Connection Pooling** (`connection_pool.zig`)
   - Reuse TCP connections to backends
   - Configurable max connections per backend
   - Automatic stale connection cleanup
   - Idle connection management

5. **Retry Logic** (`load_balancer.zig`)
   - Automatic retry on backend failure
   - Exponential backoff between retries
   - Configurable max retries (default: 3)
   - Tracks which backend failed for better routing

6. **Timeout Handling** (`load_balancer.zig`)
   - Request timeout configuration
   - Backend connection timeout
   - Health check timeout
   - (TODO: Full timeout implementation with select/poll)

## Architecture

```
LoadBalancer
├── BackendPool (Round Robin selection)
├── HealthChecker (Periodic health monitoring)
├── ConnectionPool (Connection reuse)
└── ForwardRequest (Retry + Timeout)
```

## Usage Example

```zig
const load_balancer = @import("load_balancer");

// Initialize
var lb = load_balancer.LoadBalancer.init(allocator);
defer lb.deinit();

// Add backends
try lb.addBackend("127.0.0.1", 8001);
try lb.addBackend("127.0.0.1", 8002);
try lb.addBackend("127.0.0.1", 8003);

// Forward request
const result = try lb.forwardRequest("GET", "/api/data", "", "");
defer result.deinit(allocator);

// Use response
std.log.info("Status: {}, Body: {s}", .{ result.status_code, result.body });

// Health checks (call periodically)
lb.performHealthCheck();

// Cleanup stale connections (call periodically)
lb.cleanupConnections();
```

## Configuration

- `max_retries`: Maximum retry attempts (default: 3)
- `retry_delay_ms`: Initial retry delay in milliseconds (default: 100ms)
- `request_timeout_ms`: Request timeout in milliseconds (default: 5000ms)
- `health_check_interval`: Health check interval (default: 5000ms)
- `health_check_timeout`: Health check timeout (default: 2000ms)
- `max_connections_per_backend`: Max pooled connections (default: 10)
- `max_idle_time`: Max idle time before closing connection (default: 30000ms)

## TODO / Future Enhancements

- [ ] Full timeout implementation with select/poll
- [ ] Weighted round-robin algorithm
- [ ] Least connections algorithm
- [ ] IP hash algorithm (sticky sessions)
- [ ] DNS resolution for hostnames
- [ ] HTTP/2 support for backend connections
- [ ] Metrics and observability
- [ ] Circuit breaker pattern
- [ ] Rate limiting per backend

## Integration

To integrate with the main server:

1. Initialize load balancer in `main.zig` or `io_uring.zig`
2. Replace static response generation with `lb.forwardRequest()`
3. Add periodic health check task
4. Add periodic connection cleanup task

See `LOAD-BALANCER-INTEGRATION.md` for detailed integration guide.

