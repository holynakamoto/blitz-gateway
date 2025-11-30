# Blitz Gateway Infrastructure

Production-ready Docker Compose setup following industry best practices for multi-environment deployments.

## 🏗️ Architecture

This setup implements **Tier 1** of the Docker Compose evolution pattern, providing:

- **Environment isolation** - Each environment runs in separate containers
- **Configuration management** - Environment-specific overrides
- **Scalability** - Easy to extend to more environments
- **CI/CD ready** - Optimized for automated deployments

## 📁 Structure

```
infra/
├── compose/           # Docker Compose files
│   ├── common.yml     # Base services (shared across environments)
│   ├── dev.yml        # Development overrides
│   ├── staging.yml    # Staging environment
│   ├── prod.yml       # Production environment
│   ├── ci.yml         # CI/testing environment
│   └── monitoring.yml # Monitoring stack
├── env/               # Environment variables
│   ├── env.dev        # Development config
│   ├── env.staging    # Staging config
│   └── env.prod       # Production config
└── up.sh              # Environment-aware wrapper script
```

## 🚀 Usage

### Quick Start

```bash
# Development environment (default)
./infra/up.sh dev up

# Staging environment
./infra/up.sh staging up -d

# Production environment
./infra/up.sh prod up -d

# With monitoring stack
./infra/up.sh dev --profile monitoring up
```

### Available Commands

```bash
# Development
./infra/up.sh dev up              # Start development environment
./infra/up.sh dev logs -f         # View logs
./infra/up.sh dev down            # Stop environment

# Staging
./infra/up.sh staging up -d       # Start staging (detached)
./infra/up.sh staging ps          # Check status
./infra/up.sh staging restart     # Restart services

# Production
./infra/up.sh prod up -d          # Start production
./infra/up.sh prod scale blitz-quic=5  # Scale to 5 replicas

# CI/Testing
./infra/up.sh ci up --abort-on-container-exit  # Run tests and exit

# Monitoring
./infra/up.sh monitoring up -d    # Start monitoring stack only
```

## 🌍 Environments

### Development (`dev`)
- **Hot reloading** enabled
- **Source code mounting** for live development
- **Debug logging** and development tools
- **Ports exposed** for local access
- **Resource limits** relaxed for development

### Staging (`staging`)
- **Production-like configuration**
- **Multiple replicas** for testing
- **External access** via ports
- **Monitoring** enabled
- **Real certificates** (if available)

### Production (`prod`)
- **Optimized for performance**
- **No source mounting** (immutable containers)
- **Minimal ports exposed**
- **High availability** with replicas
- **Production certificates** required

### CI (`ci`)
- **No ports exposed** (isolated testing)
- **Test database** available
- **Fast startup/shutdown**
- **Minimal resource usage**

## 📊 Monitoring

The monitoring stack includes Prometheus, Grafana, and Node Exporter.

```bash
# Start with monitoring
./infra/up.sh dev --profile monitoring up -d

# Access dashboards
# - Grafana: http://localhost:3000 (admin/admin)
# - Prometheus: http://localhost:9090
```

## 🔧 Configuration

### Environment Variables

Each environment has its own `.env` file in `infra/env/`:

```bash
# Development
ENV=development
DEBUG=1
QUIC_LOG=debug
CPU_LIMIT=2

# Production
ENV=production
DEBUG=0
QUIC_LOG=warn
REPLICAS=3
```

### Customizing Services

To add environment-specific services or overrides:

1. **Edit the compose file**: `infra/compose/{env}.yml`
2. **Add environment variables**: `infra/env/env.{env}`
3. **Test the changes**: `./infra/up.sh {env} up`

### Scaling

```bash
# Scale production replicas
./infra/up.sh prod up -d --scale blitz-quic=10

# Scale specific services
docker compose -p blitz-prod up -d --scale blitz-quic=5
```

## 🔒 Security

### Production Considerations

- **Certificates**: Mount real TLS certificates in production
- **Secrets**: Use Docker secrets or external secret management
- **Network isolation**: Configure proper network policies
- **Resource limits**: Set appropriate CPU/memory limits
- **Updates**: Use rolling updates for zero-downtime deployments

### Secrets Management

For production, consider:

```bash
# Docker secrets (Swarm mode)
echo "my-secret-key" | docker secret create jwt_secret -

# Or environment variables (less secure)
JWT_SECRET=your-secret-key ./infra/up.sh prod up -d
```

## 🧪 Testing

### Local Testing

```bash
# Start development environment
./infra/up.sh dev up

# Run integration tests
curl http://localhost:8080/health
curl -H "Authorization: Bearer [token]" http://localhost:8080/api/profile
```

### CI/CD Integration

The CI environment is optimized for automated testing:

```bash
# In GitHub Actions
./infra/up.sh ci up --abort-on-container-exit
```

## 📈 Scaling Up

When you need more advanced features:

### Tier 2: Infrastructure as Code
- **Terraform**: For cloud resource management
- **Pulumi**: If you prefer programming languages
- **Kubernetes**: For container orchestration

### Migration Path

```bash
# Current: Docker Compose
./infra/up.sh prod up -d

# Future: Kubernetes
kubectl apply -f k8s/production/
```

## 🐛 Troubleshooting

### Common Issues

**Port conflicts:**
```bash
# Check what's using ports
lsof -i :8080
./infra/up.sh dev down
```

**Container logs:**
```bash
./infra/up.sh dev logs -f blitz-quic
```

**Resource issues:**
```bash
# Check resource usage
docker stats
```

### Reset Everything

```bash
# Stop all environments
./infra/up.sh dev down -v --remove-orphans
./infra/up.sh staging down -v --remove-orphans
./infra/up.sh prod down -v --remove-orphans

# Clean up networks and volumes
docker system prune -f
```

## 📚 Related Documentation

- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Production Docker Deployments](https://docs.docker.com/compose/production/)
- [Docker Security Best Practices](https://docs.docker.com/develop/security-best-practices/)
