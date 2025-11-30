# Directory Structure

Overview of the Blitz Gateway project structure.

## Root Directory

**Essential files (keep in root):**
- `README.md` - Main project documentation
- `ROADMAP.md` - Project roadmap
- `LICENSE` - Apache 2.0 license
- `build.zig` - Zig build configuration
- `Dockerfile` - Docker image definition
- `Vagrantfile` - Vagrant VM configuration
- `Makefile` - Common commands
- `install.sh` - One-command install script
- `nfpm.yaml` - Package build configuration
- `lb.example.toml` - Load balancer config example

## Documentation (`docs/`)

All documentation is organized by topic:

- `docs/INDEX.md` - Documentation navigation
- `docs/release/` - Release and publishing guides
- `docs/packaging/` - Package installation and testing
- `docs/dev/` - Development setup and guides
- `docs/benchmark/` - Benchmarking guides
- `docs/production/` - Production deployment
- `docs/quic/` - QUIC implementation details

## Scripts (`scripts/`)

Organized by purpose:

- `scripts/release/` - Release automation
- `scripts/bench/` - Benchmarking scripts
- `scripts/vm/` - VM setup scripts
- `scripts/docker/` - Docker utilities
- `scripts/misc/` - Miscellaneous utilities

## Infrastructure (`infra/`)

Infrastructure as Code:

- `infra/compose/` - Docker Compose configurations
- `infra/k8s/` - Kubernetes manifests
- `infra/helm/` - Helm charts
- `infra/aws/` - AWS CloudFormation
- `infra/monitoring/` - Monitoring configurations
- `infra/config/` - Configuration templates
- `infra/env/` - Environment variable files

## Packaging (`packaging/`)

Package build files:

- `packaging/systemd/` - Systemd service files
- `packaging/config/` - Default configurations
- `packaging/scripts/` - Package install/remove scripts
- `packaging/build-deb.sh` - Local package builder

## Source Code (`src/`)

Application source code organized by feature.

## Tests (`tests/`)

Test files mirroring source structure.

## Benchmarks

- `benches/` - Standard benchmark suite
- `nuclear-benchmarks/` - Advanced competitive benchmarks

