# Load Balancer Tests

Comprehensive test suite for the load balancer modules.

## Running Tests

### Option 1: Direct Zig Test (Recommended)

```bash
cd /Users/nickmoore/blitz-gateway
zig test src/load_balancer/test.zig -I src
```

### Option 2: Via Build System (if build.zig is updated)

```bash
zig build test-load-balancer
```

## Test Coverage

### ✅ Backend Pool Tests
- Initialize and add backends
- Round-robin selection algorithm
- Health status tracking
- Statistics tracking
- Round-robin skips unhealthy backends

### ✅ Connection Pool Tests
- Initialize and manage connections
- Mark connections as used/idle
- Stale connection detection

### ✅ Load Balancer Integration Tests
- Initialize and add backends
- Configuration validation
- Statistics collection

### ✅ Health Check Tests
- Initialize health checker
- Start/stop health check loop

### ✅ Request Building Tests
- Build HTTP GET request
- Build HTTP POST request with body
- Parse HTTP status codes

## Test Results

All tests should pass. Some tests that require actual backend servers (like connection pool tests) are marked as structure tests only.

## Adding New Tests

To add new tests, edit `src/load_balancer/test.zig` and follow the existing pattern:

```zig
test "Test Name" {
    std.debug.print("[TEST] Description... ", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Your test code here
    
    std.debug.print("✅ PASSED\n", .{});
}
```

## Note on Integration Tests

Some tests (like connection pooling with actual TCP connections) require:
1. Backend servers running on test ports
2. Mock servers for isolated testing
3. Or integration test environment

These are marked in the test output and can be enhanced with mock servers in the future.

