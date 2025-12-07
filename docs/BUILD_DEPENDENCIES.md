# Build Dependencies Map

## Overview

Blitz Gateway is built entirely in Zig:
- **Zig**: Core application, HTTP/1.1, HTTP/2, load balancing, middleware
- **HTTP/3**: Handled by Caddy (see `scripts/bench/bench.sh` for setup)

## Build Flow

```
┌─────────────────────────────────────────────────────────┐
│  Zig Build System (build.zig)                           │
├─────────────────────────────────────────────────────────┤
│  1. Compile Zig sources                                 │
│  2. Link static libraries:                              │
│     - liburing-ffi.a                                    │
│     - libpicotls.a (if using legacy Picoquic)          │
│  3. Link system libraries:                              │
│     - pthread, dl (if needed)                            │
└─────────────────────────────────────────────────────────┘
```

## Dependencies

### System Requirements (VM)
- **OS**: Ubuntu 22.04 LTS
- **Multipass**: For VM management
- **RAM**: 12GB (recommended)
- **Disk**: 50GB (for dependencies and build artifacts)

### Build Tools (Installed by linux-build.sh)

1. **Zig 0.15.2** (via snap)
   - Used for compiling Zig code
   - Handles cross-compilation

2. **C/C++ Toolchain**
   - `build-essential`
   - `cmake` (for building dependencies)
   - `gcc`, `make`

3. **Other Tools**
   - `git` (for cloning dependencies)
   - `rsync` (for syncing files to VM)
   - `pkg-config`

### Static Libraries (Built in VM)

1. **liburing-ffi (v2.7)**
   - Location: `/usr/local/lib/liburing-ffi.a`
   - Headers: `/usr/local/include/liburing/`
   - Purpose: io_uring FFI for Zig
   - Build: Built from source during VM setup

2. **picotls** (optional - for legacy Picoquic)
   - Location: `/usr/local/lib/libpicotls.a`
   - Headers: `/usr/local/include/picotls/`
   - Purpose: TLS operations (if using legacy code)
   - Build: Built from `deps/picotls/` during VM setup

### System Libraries (Dynamic - Minimal)

Only these are dynamically linked if needed:
- **pthread** - POSIX threads
- **dl** - Dynamic loading

## Build Process

### 1. VM Setup (`linux-build.sh`)
```bash
./scripts/vm/linux-build.sh build
```

**What it does:**
- Creates Ubuntu 22.04 VM (if needed)
- Installs Zig 0.15.2 (snap)
- Builds liburing-ffi from source
- Builds picotls (if needed)
- Syncs project files to VM

### 2. Zig Executable Build (automatic)

When `zig build` runs:
- Compiles all Zig sources
- Links liburing-ffi via `addObjectFile()`
- Links system libraries (pthread, dl) if needed
- Output: `zig-out/bin/blitz`

## File Locations

### Source Files
- `src/main.zig` - Zig main entry point
- `src/http/` - HTTP/1.1 implementation
- `src/http2/` - HTTP/2 (h2c) implementation
- `src/load_balancer/` - Load balancing logic
- `src/middleware/` - Middleware (rate limiting, etc.)
- `build.zig` - Zig build configuration

### Output Files
- `zig-out/bin/blitz` - Final executable

### Configuration
- `config/proxy_rules.json` - Proxy routing rules (optional)

## HTTP/3 Setup

HTTP/3 is handled by Caddy, not Zig. To set up Caddy for HTTP/3 benchmarking:

1. See `scripts/bench/bench.sh` for automatic Caddy setup
2. Or manually:
   ```bash
   git clone https://github.com/caddyserver/caddy.git
   cd caddy/cmd/caddy/
   go build
   ```

## Verification Checklist

Before running `linux-build.sh`:

- [x] Multipass installed (`multipass version`)
- [x] Project files synced to VM
- [x] Zig installed in VM
- [x] liburing-ffi built and installed
- [x] `build.zig` configured correctly

## Potential Issues

### Library Not Found
**Symptom**: `error: failed to link with 'liburing-ffi'`
**Fix**: Verify liburing-ffi was built:
```bash
ls -la /usr/local/lib/liburing-ffi.a
```

### Missing Dependencies
**Symptom**: Build fails with missing headers
**Fix**: Ensure all dependencies are installed in VM:
```bash
multipass exec zig-build -- sudo apt-get install -y build-essential cmake
```
