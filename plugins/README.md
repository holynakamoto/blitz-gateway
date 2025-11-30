# Blitz Gateway WASM Plugins

This directory contains WASM plugins for the Blitz Edge Gateway. Plugins extend gateway functionality without modifying core code.

## Plugin Architecture

Blitz plugins are WebAssembly (WASM) modules that implement specific interfaces:

- **Request Preprocessing**: Modify requests before routing
- **Authentication**: Custom auth logic
- **Request Transformation**: Modify request content
- **Response Transformation**: Modify response content
- **Observability**: Custom metrics/logging

## Plugin Interface

Plugins must export these functions:

```wasm
// Called during plugin initialization
fn init() -> i32

// Process incoming requests
fn process_request(method: string, path: string) -> i32

// Process outgoing responses
fn process_response(status: i32, body: string) -> i32

// Called during plugin cleanup
fn cleanup() -> i32
```

Return codes:
- `0`: Continue processing
- `1`: Stop processing (success)
- `-1`: Error occurred

## Host Functions

Plugins can call these host functions:

```wasm
// Logging
fn log(level: string, message: string)

// Environment variables
fn get_env(name: string) -> string

// HTTP headers
fn set_header(name: string, value: string)
fn get_header(name: string) -> string

// Request body
fn get_body() -> string
```

## Development

### Creating a Plugin

1. **Write plugin in supported language** (Rust, C++, Go, etc.)
2. **Compile to WASM** with WASI support
3. **Implement required interface functions**
4. **Test with Blitz gateway**
5. **Deploy to plugins directory**

### Example Plugin (Rust)

```rust
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
extern "C" {
    fn log(level: &str, message: &str);
    fn set_header(name: &str, value: &str);
}

#[wasm_bindgen]
pub fn init() -> i32 {
    log("info", "Request logging plugin initialized");
    0
}

#[wasm_bindgen]
pub fn process_request(method: &str, path: &str) -> i32 {
    let msg = format!("Request: {} {}", method, path);
    log("info", &msg);
    0
}

#[wasm_bindgen]
pub fn process_response(status: i32, _body: &str) -> i32 {
    if status >= 400 {
        set_header("X-Error-Logged", "true");
    }
    0
}

#[wasm_bindgen]
pub fn cleanup() -> i32 {
    log("info", "Request logging plugin cleaned up");
    0
}
```

### Building WASM Plugin

```bash
# Rust
wasm-pack build --target web --out-dir pkg

# Copy to plugins directory
cp pkg/plugin_bg.wasm /path/to/blitz/plugins/request_logger.wasm
```

### Configuration

Plugins are auto-discovered from the `plugins/` directory. Configure in `infra/compose/dev.yml`:

```yaml
services:
  blitz-quic:
    environment:
      - PLUGIN_DIR=/app/plugins
      - PLUGIN_MEMORY_LIMIT=2097152  # 2MB
      - PLUGIN_TIMEOUT=3000          # 3 seconds
```

## Built-in Plugins

### Request Logger
- **File**: `request_logger.wasm`
- **Purpose**: Logs all incoming requests
- **Type**: Request preprocessing

### Rate Limiter
- **File**: `rate_limiter.wasm`
- **Purpose**: Custom rate limiting logic
- **Type**: Request preprocessing

### Auth Custom
- **File**: `auth_custom.wasm`
- **Purpose**: Custom authentication beyond JWT
- **Type**: Authentication

## Security

- **Sandboxing**: Plugins run in isolated WASM environment
- **Resource Limits**: Memory and execution time limits
- **Host Access**: Only explicitly allowed host functions
- **Validation**: Plugin bytecode verified before loading

## Performance

- **Startup**: ~10-50ms per plugin
- **Execution**: ~1-5ms per request (depending on logic)
- **Memory**: ~100KB-2MB per plugin instance
- **Scaling**: Multiple instances supported

## Debugging

Enable debug logging:

```bash
export QUIC_LOG=debug
export PLUGIN_LOG=trace
./infra/up.sh dev up
```

Check plugin logs:

```bash
docker logs blitz-dev
# Look for [WASM Plugin] messages
```

## Deployment

```bash
# Development
./infra/up.sh dev up

# Production
./infra/up.sh prod up -d

# With plugins
./infra/up.sh dev --profile with-plugins up
```

## Troubleshooting

**Plugin not loading:**
- Check file permissions
- Verify WASM format (`wasm-validate plugin.wasm`)
- Check gateway logs for errors

**Plugin crashing:**
- Enable debug logging
- Check memory limits
- Verify host function usage

**Performance issues:**
- Profile with `perf` or similar
- Check execution timeouts
- Monitor memory usage
