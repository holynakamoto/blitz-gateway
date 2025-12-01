## Description

<!-- Provide a clear and concise description of your changes -->



## Type of Change

<!-- Mark the relevant option with an "x" -->

- [ ] 🐛 Bug fix (non-breaking change that fixes an issue)
- [ ] ✨ New feature (non-breaking change that adds functionality)
- [ ] ⚡ Performance improvement
- [ ] ♻️ Code refactoring (no functional changes)
- [ ] 📝 Documentation update
- [ ] 🧪 Test additions or updates
- [ ] 🔧 Configuration changes
- [ ] 🚨 Breaking change (fix or feature that would cause existing functionality to change)

## Performance Impact

<!-- Mark the relevant option and provide benchmarks if applicable -->

- [ ] No performance impact
- [ ] Improves performance
- [ ] May degrade performance (justified below)

### Benchmarks

<!-- If performance-related, include before/after benchmarks -->

```
Before:
  Throughput: X req/s
  Latency p99: Y µs
  Memory: Z MB

After:
  Throughput: X req/s
  Latency p99: Y µs
  Memory: Z MB
```

## Breaking Changes

<!-- Mark and describe any breaking changes -->

- [ ] This PR introduces NO breaking changes
- [ ] This PR introduces breaking changes (described below)

### Breaking Change Details

<!-- If applicable, describe:
  - What breaks
  - Why it was necessary
  - Migration path for users
-->

### Migration Guide

<!-- If breaking, provide step-by-step migration instructions -->

## Security Considerations

<!-- Mark if this PR has security implications -->

- [ ] This PR has no security implications
- [ ] This PR affects authentication/authorization
- [ ] This PR affects rate limiting or DoS protection
- [ ] This PR modifies cryptographic operations
- [ ] This PR changes input validation

### Security Review Notes

<!-- If security-related, explain the security considerations -->

## Testing

<!-- Describe the tests you ran and how to reproduce -->

### Test Coverage

- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [ ] E2E tests added/updated
- [ ] Performance benchmarks run
- [ ] Manual testing performed

### Test Results

<!-- Paste relevant test output -->

```
$ zig build test
All tests passed (XX/XX)
```

### Manual Testing Steps

1. 
2. 
3. 

## Checklist

<!-- Ensure all items are complete before requesting review -->

- [ ] Code follows the project's style guidelines (run `zig fmt`)
- [ ] Self-reviewed the code
- [ ] Commented complex or non-obvious code
- [ ] Updated documentation (if applicable)
- [ ] No new warnings introduced
- [ ] Added tests that prove the fix/feature works
- [ ] New and existing tests pass locally
- [ ] No performance regressions (benchmarked)
- [ ] Considered memory safety (proper alloc/free patterns)
- [ ] Updated CHANGELOG.md (if user-facing change)
- [ ] Linked related issues (closes #XXX)

## Memory Safety Review

<!-- For any code that allocates memory -->

- [ ] All allocations have clear ownership
- [ ] Proper use of `defer` or `errdefer` for cleanup
- [ ] No potential memory leaks identified
- [ ] Tested with memory leak detection tools
- [ ] Arena allocator used appropriately for request-scoped allocations

## Additional Context

<!-- Add any other context, screenshots, or relevant information -->

## Related Issues

<!-- Link related issues -->

Closes #
Relates to #

---

## For Reviewers

<!-- Guidance for reviewers -->

### Focus Areas

<!-- Highlight specific areas that need careful review -->

- 
- 

### Potential Concerns

<!-- Any concerns or areas of uncertainty -->

- 
- 

---

<!-- 
PR Title Convention:
  type(scope): description
  
  Types: feat, fix, perf, refactor, docs, test, chore, ci
  Scopes: core, io_uring, http, proxy, auth, ratelimit, wasm, metrics, config, quic, load_balancer
  
  Examples:
    feat(http): Add HTTP/3 support
    fix(proxy): Resolve connection pool leak
    perf(io_uring): Optimize batch submission
    feat(auth)!: Migrate to new JWT validation (breaking change)
-->
