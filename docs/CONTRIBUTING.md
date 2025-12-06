# Contributing to Blitz

Thank you for your interest in contributing to Blitz! We're building the fastest edge proxy ever written, and every contribution helps us get closer to 10M+ RPS and <50µs p99 latency.

## 🎯 Our Mission

We're not just building another proxy. We're building infrastructure that will force Cloudflare, Fastly, AWS, and Google to acquire us. Every line of code must be optimized for:

- **Latency**: Sub-50µs p99 is non-negotiable
- **Throughput**: 10M+ RPS on commodity hardware
- **Memory**: Zero heap allocations after startup (arena + slab only)
- **Safety**: Zig's memory safety guarantees are our foundation

## 🚀 Getting Started

1. **Fork the repository**
2. **Clone your fork**:
   ```bash
   git clone https://github.com/your-username/blitz.git
   cd blitz
   ```
3. **Set up your development environment**:
   - Install Zig 0.12.0+
   - Install liburing (see README.md)
   - Run `zig build test` to verify setup

## 📝 Development Workflow

### Branch Naming

- `feature/` - New features
- `fix/` - Bug fixes
- `perf/` - Performance improvements
- `docs/` - Documentation updates
- `refactor/` - Code refactoring

### Code Style

- Follow Zig's official style guide
- Use `zig fmt` before committing
- Maximum line length: 100 characters
- Prefer explicit error handling over panics
- Document all public APIs

### Performance Requirements

**Every PR must include benchmarks:**

```bash
# Before your changes
wrk2 -t4 -c100 -d30s -R1000000 http://localhost:8080/ > before.txt

# After your changes
wrk2 -t4 -c100 -d30s -R1000000 http://localhost:8080/ > after.txt

# Compare
diff before.txt after.txt
```

**Performance regressions are not acceptable.** If your change adds latency or reduces throughput, you must:
1. Justify why it's necessary
2. Optimize other parts of the codebase to compensate
3. Get explicit approval from maintainers

### Memory Safety

- **Zero heap allocations** in hot paths (after startup)
- Use arena allocators for request-scoped data
- Use slab allocators for connection pools
- Never use `std.heap.page_allocator` in request handling
- All allocations must be bounded and checked

### Testing

- Write unit tests for all new functions
- Write integration tests for new features
- Run `zig build test` before submitting PR
- Aim for >80% code coverage on new code

### Commit Messages

Follow conventional commits:

```
feat: add HTTP/2 support
fix: correct io_uring connection handling
perf: optimize HTTP parser with SIMD
docs: update README with benchmark results
```

## 🔍 Code Review Process

1. **Submit a PR** with a clear description
2. **Wait for CI** to pass (all tests + benchmarks)
3. **Address review comments** promptly
4. **Get approval** from at least one maintainer
5. **Squash and merge** (maintainers will handle this)

### What We Look For

- ✅ Performance improvements or no regressions
- ✅ Memory safety (no leaks, no use-after-free)
- ✅ Clear, readable code
- ✅ Comprehensive tests
- ✅ Updated documentation
- ✅ Benchmark results included

### What We Reject

- ❌ Performance regressions without justification
- ❌ Heap allocations in hot paths
- ❌ Unsafe code without clear justification
- ❌ Missing tests
- ❌ Breaking changes without discussion

## 🎯 Priority Areas

We're especially interested in contributions to:

1. **HTTP/2 and HTTP/3 (QUIC) support**
2. **TLS 1.3 zero-copy implementation**
3. **WASM plugin runtime optimization**
4. **eBPF integration for routing**
5. **SIMD-optimized HTTP parsing**
6. **Connection pooling and reuse**
7. **OpenTelemetry integration**
8. **Hot reload system**

## 🐛 Reporting Bugs

Use GitHub Issues with:

- **Title**: Clear, descriptive summary
- **Description**: Steps to reproduce
- **Expected behavior**: What should happen
- **Actual behavior**: What actually happens
- **Environment**: OS, Zig version, liburing version
- **Benchmarks**: If performance-related, include `wrk2` results

## 💡 Feature Requests

Open a GitHub Discussion first to:
- Validate the feature aligns with our goals
- Discuss implementation approach
- Get feedback from maintainers

Then create an issue with the `enhancement` label.

## 📊 Benchmarking Guidelines

All performance-related PRs must include:

1. **Hardware specs**: CPU, RAM, OS, kernel version
2. **Test methodology**: wrk2/hey command used
3. **Before/after results**: RPS, latency (p50, p99, p99.9)
4. **Statistical significance**: Multiple runs, confidence intervals

Example:

```markdown
## Benchmark Results

**Hardware**: AMD EPYC 7763, 128 cores, 256GB RAM, Linux 6.1.0
**Methodology**: `wrk2 -t16 -c1000 -d60s -R5000000 http://localhost:8080/`

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| RPS    | 4.2M   | 4.8M  | +14%   |
| p99    | 95µs   | 82µs  | -14%   |
| p99.9  | 180µs  | 150µs | -17%   |
```

## 🤝 Code of Conduct

- Be respectful and professional
- Focus on technical merit
- Help others learn and grow
- Celebrate wins together

## 📞 Questions?

- Open a GitHub Discussion
- Join our Discord (coming soon)
- Tag maintainers in issues/PRs

## 🏆 Recognition

Contributors will be:
- Listed in CONTRIBUTORS.md
- Mentioned in release notes
- Invited to join the core team (for significant contributions)

**Let's build the fastest infrastructure software ever written. Every microsecond matters.**

LFG. 🚀

