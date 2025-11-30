# Documentation Index

Quick navigation to all Blitz Gateway documentation.

## 🚀 Getting Started

- **[README](../README.md)** - Project overview and quick start
- **[QUICKSTART](dev/QUICKSTART.md)** - 10-minute setup guide
- **[Installation](packaging/README.md)** - Package installation guide

## 📦 Installation & Packaging

- **[Packaging Guide](packaging/README.md)** - .deb package system
- **[Publishing Guide](release/PUBLISHING.md)** - Publish to APT & Docker
- **[Quick Publish](release/QUICK-PUBLISH.md)** - One-command release
- **[Release Checklist](release/RELEASE-CHECKLIST.md)** - Release verification
- **[Test Installation](packaging/TEST-INSTALL.md)** - Test install scripts
- **[Install Quickstart](packaging/TEST-INSTALL-QUICKSTART.md)** - Quick test guide

## 🏗️ Development

- **[Contributing](CONTRIBUTING.md)** - Development guidelines
- **[Docker Guide](dev/DOCKER-GUIDE.md)** - Docker development setup
- **[Vagrant Guide](dev/VAGRANT-GUIDE.md)** - Vagrant VM setup
- **[UTM Setup](dev/UTM-DIRECT-SETUP.md)** - UTM VM setup (Apple Silicon)
- **[Apple Silicon Setup](dev/APPLE-SILICON-SETUP.md)** - ARM Mac setup
- **[Zig Migration](dev/ZIG-0.15.2-MIGRATION.md)** - Zig version updates

## 🏭 Production Deployment

- **[Production Deployment](production/README.md)** - Docker, K8s, AWS, Bare Metal
- **[Infrastructure](infra/README.md)** - Docker Compose infrastructure

## 📊 Benchmarking

- **[Benchmarking Guide](benchmark/README.md)** - Performance testing
- **[VM Setup](benchmark/VM-SETUP.md)** - Benchmark VM setup
- **[VM Quick Start](benchmark/VM-QUICK-START.md)** - Quick VM setup
- **[Bare Metal Setup](benchmark/QUICK-START-BARE-METAL.md)** - Production benchmarking
- **[VM Benchmarking](benchmark/BENCHMARKING-VM.md)** - VM-specific guide

## 🔧 Architecture & Technical

- **[HTTP/3 Implementation](HTTP3-IMPLEMENTATION.md)** - QUIC/HTTP3 details
- **[HTTP/2 Features](HTTP2-FEATURES.md)** - HTTP/2 implementation
- **[QUIC Progress](quic/QUIC-PROGRESS-SUMMARY.md)** - QUIC development
- **[TLS/HTTP2 Integration](TLS-HTTP2-INTEGRATION.md)** - TLS implementation

## 📝 Scripts

- **Release**: `scripts/release/PUBLISH-RELEASE.sh`
- **Benchmarks**: `scripts/bench/`
- **VM Setup**: `scripts/vm/`
- **Docker**: `scripts/docker/`

## 📁 Directory Structure

```
blitz-gateway/
├── README.md                    # Main project README
├── ROADMAP.md                   # Project roadmap
├── install.sh                   # One-command install script
├── build.zig                    # Zig build configuration
├── Dockerfile                   # Docker build file
├── Vagrantfile                  # Vagrant VM configuration
├── nfpm.yaml                    # Package build configuration
│
├── docs/                        # All documentation
│   ├── INDEX.md                # This file
│   ├── release/                # Release & publishing docs
│   ├── packaging/              # Packaging & installation
│   ├── dev/                    # Development guides
│   ├── benchmark/              # Benchmarking guides
│   ├── production/             # Production deployment
│   └── quic/                   # QUIC implementation docs
│
├── scripts/                     # All scripts
│   ├── release/                # Release automation
│   ├── bench/                  # Benchmarking scripts
│   ├── vm/                     # VM setup scripts
│   └── docker/                 # Docker utilities
│
├── infra/                       # Infrastructure as Code
│   ├── compose/                # Docker Compose configs
│   ├── k8s/                    # Kubernetes manifests
│   ├── helm/                   # Helm charts
│   ├── aws/                    # AWS CloudFormation
│   └── monitoring/             # Monitoring configs
│
└── packaging/                   # Package build files
    ├── systemd/                # Systemd service files
    ├── config/                 # Default configurations
    └── scripts/                # Package scripts
```

## 🔍 Quick Links

**Common Tasks:**
- Install: `curl ... | sudo bash` or see [Installation Guide](packaging/README.md)
- Develop: See [Development Guides](dev/)
- Deploy: See [Production Deployment](production/README.md)
- Benchmark: See [Benchmarking Guide](benchmark/README.md)
- Release: `./scripts/release/PUBLISH-RELEASE.sh` or see [Publishing Guide](release/PUBLISHING.md)

