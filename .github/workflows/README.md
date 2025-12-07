# GitHub Actions Workflows

This directory contains GitHub Actions workflows for automated testing, building, and deployment of Blitz Gateway.

## Workflows Overview

### 🚀 [`ci-cd.yml`](ci-cd.yml) - Main CI/CD Pipeline
**Triggers**: Push/PR to main/develop branches, version tags, manual dispatch

Comprehensive pipeline covering:
- **Static Analysis & Linting**: Zig format checking, custom linter patterns, Shellcheck
- **Security Scanning**: Semgrep, TruffleHog secret scanning, dependency vulnerability checks
- **Build & Test**: Multi-platform builds (Linux x86_64, ARM64, macOS), comprehensive test suites
- **Performance**: Performance benchmarks on PRs
- **Memory Safety**: Memory leak detection, sanitizer checks
- **Container**: Multi-arch Docker builds, container security scanning, smoke tests
- **Release**: Automated GitHub releases with changelog generation

### 📦 [`release-deb.yml`](release-deb.yml) - Debian Package Release
**Triggers**: Version tags (v*.*.*) or manual dispatch

- Builds optimized `.deb` packages using `nfpm`
- Publishes to GitHub Releases
- Includes systemd service and configuration files

### 📊 [`benchmark.yml`](benchmark.yml) - Performance Testing
**Triggers**: Push to benchmark branch, changes to bench code, or manual dispatch

- Comprehensive performance benchmarks
- Regression detection against baseline
- Resource monitoring (memory, CPU)
- Benchmark script validation

### 🔄 [`dependencies.yml`](dependencies.yml) - Dependency Management
**Triggers**: Daily schedule (2 AM UTC) or manual dispatch

- Zig version update detection
- PicoTLS submodule update checking
- Security vulnerability scanning
- Automated update notifications

### 📚 [`docs.yml`](docs.yml) - Documentation Validation
**Triggers**: Changes to docs, README, or weekly schedule

- Documentation structure validation
- Link checking
- Required file verification
- Repository structure checks

## Workflow Badges

Add these badges to your README.md:

```markdown
[![CI/CD](https://github.com/holynakamoto/blitz-gateway/workflows/Blitz%20Gateway%20CI%2FCD/badge.svg)](https://github.com/holynakamoto/blitz-gateway/actions)
[![Benchmark](https://github.com/holynakamoto/blitz-gateway/workflows/Benchmark/badge.svg)](https://github.com/holynakamoto/blitz-gateway/actions)
```

## Key Features

### 🔧 **Automated Testing**
- Multi-platform Zig builds (Linux x64/ARM64, macOS ARM64)
- Comprehensive test suite coverage
- Integration and unit tests
- Container validation

### 📈 **Performance Monitoring**
- Benchmark regression detection
- Resource usage tracking
- Memory leak detection
- Performance baseline comparisons

### 🔒 **Security & Quality**
- Security pattern scanning (Semgrep)
- Secret scanning (TruffleHog)
- Dependency vulnerability scanning
- Code formatting enforcement

### 🚀 **Release Automation**
- Semantic versioning support
- Multi-arch Docker image publishing
- Debian package building
- Automated changelog generation

## Manual Triggers

All workflows support manual execution via `workflow_dispatch`:
- **CI/CD**: Full pipeline execution
- **Benchmark**: Custom benchmark parameters
- **Dependencies**: Manual dependency checks
- **Release-deb**: Manual package builds

## Environment Requirements

### GitHub Secrets
- `GITHUB_TOKEN`: Automatically provided
- `PACKAGECLOUD_TOKEN`: Optional, for APT repository publishing

### External Dependencies
- **GitHub Container Registry**: For publishing Docker images (ghcr.io)
- **GitHub Releases**: For binary and package distribution

### Runner Requirements
- **Ubuntu**: Full Linux testing with io_uring support
- **macOS**: Cross-platform compatibility testing
- **Docker**: Container build and testing capabilities

## Contributing

When adding new workflows:

1. **Name consistently**: Use descriptive, action-oriented names
2. **Trigger appropriately**: Balance coverage with resource usage
3. **Document thoroughly**: Update this README with new workflows
4. **Test manually**: Use `workflow_dispatch` for validation
5. **Optimize performance**: Use caching and conditional execution

## Troubleshooting

### Common Issues

**Workflow doesn't trigger**: Check branch protection rules and path filters

**Container builds fail**: Ensure Dockerfile syntax and base images are valid

**Test failures**: Check Zig version compatibility and system dependencies

**Release failures**: Verify tagging format and GitHub token permissions

### Debug Mode

Enable debug logging by setting repository secret `ACTIONS_RUNNER_DEBUG=true`

### Performance Optimization

- Use caching for dependencies and build artifacts
- Run expensive jobs only on relevant changes
- Use matrix builds for parallel execution
- Implement early exits for failed prerequisite jobs
