# Production Deployment Guide

This guide covers deploying Blitz Gateway to production environments with high availability, security, and performance.

## Table of Contents

- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [Infrastructure Options](#infrastructure-options)
- [Docker Production Deployment](#docker-production-deployment)
- [Load Balancing & Scaling](#load-balancing--scaling)
- [Monitoring & Observability](#monitoring--observability)
- [Security Hardening](#security-hardening)
- [Performance Tuning](#performance-tuning)
- [Backup & Recovery](#backup--recovery)
- [Troubleshooting](#troubleshooting)

## Quick Start

### Single Instance (Development/Testing)

```bash
# Clone repository
git clone https://github.com/blitz-gateway/blitz-gateway
cd blitz-gateway

# Start with monitoring
make monitoring up -d

# Deploy Blitz Gateway
make prod up -d

# Check health
curl http://localhost:8080/health
```

### Production Cluster (Recommended)

```bash
# Deploy monitoring stack
kubectl apply -f infra/k8s/monitoring/

# Deploy Blitz Gateway with ingress
kubectl apply -f infra/k8s/blitz-gateway/

# Scale to 3 replicas
kubectl scale deployment blitz-gateway --replicas=3

# Check cluster health
kubectl get pods -l app=blitz-gateway
```

## Prerequisites

### System Requirements

- **OS**: Linux (Ubuntu 20.04+, CentOS 8+, RHEL 8+)
- **CPU**: 4+ cores (8+ recommended)
- **RAM**: 4GB minimum, 16GB+ recommended
- **Storage**: 50GB SSD minimum
- **Network**: 1Gbps+ bandwidth

### Software Dependencies

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install -y docker.io docker-compose-plugin git curl

# CentOS/RHEL
sudo yum install -y docker docker-compose git curl

# Enable and start Docker
sudo systemctl enable docker
sudo systemctl start docker
```

### Network Requirements

- **Inbound Ports**:
  - `80` (HTTP)
  - `443` (HTTPS)
  - `8443` (QUIC/HTTP3 UDP)
  - `9090` (Prometheus metrics)
  - `3000` (Grafana dashboard)

- **Outbound Access**:
  - Docker registries
  - Let's Encrypt (for TLS certificates)
  - Monitoring endpoints

## Infrastructure Options

### Option 1: Docker Compose (Simple)

Best for small deployments, development, or single-server production.

```yaml
# infra/compose/prod.yml
version: '3.8'

services:
  blitz-gateway:
    image: blitzgateway/blitz-quic:latest
    ports:
      - "80:8080"
      - "443:8443"
      - "8443:8443/udp"
    environment:
      - ENV=production
      - QUIC_LOG=warn
    volumes:
      - ./certs:/app/certs:ro
      - ./config:/app/config:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
```

### Option 2: Kubernetes (Recommended)

Best for production with high availability and scaling.

```yaml
# infra/k8s/blitz-gateway/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blitz-gateway
  labels:
    app: blitz-gateway
spec:
  replicas: 3
  selector:
    matchLabels:
      app: blitz-gateway
  template:
    metadata:
      labels:
        app: blitz-gateway
    spec:
      containers:
      - name: blitz-gateway
        image: blitzgateway/blitz-quic:latest
        ports:
        - containerPort: 8080
          name: http
        - containerPort: 8443
          name: https
          protocol: TCP
        - containerPort: 8443
          name: quic
          protocol: UDP
        env:
        - name: ENV
          value: "production"
        - name: QUIC_LOG
          value: "warn"
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "2000m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
```

### Option 3: AWS ECS/Fargate

For serverless container deployments.

```json
{
  "family": "blitz-gateway",
  "taskRoleArn": "arn:aws:iam::123456789012:role/ecsTaskRole",
  "executionRoleArn": "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "containerDefinitions": [
    {
      "name": "blitz-gateway",
      "image": "blitzgateway/blitz-quic:latest",
      "essential": true,
      "portMappings": [
        {"containerPort": 8080, "hostPort": 8080},
        {"containerPort": 8443, "hostPort": 8443},
        {"containerPort": 8443, "hostPort": 8443, "protocol": "udp"}
      ],
      "environment": [
        {"name": "ENV", "value": "production"},
        {"name": "QUIC_LOG", "value": "warn"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/blitz-gateway",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
```

### Option 4: Bare Metal

For maximum performance with direct hardware access.

```bash
#!/bin/bash
# Production deployment script

# Install dependencies
sudo apt update
sudo apt install -y build-essential git curl

# Install Zig
wget https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz
sudo tar -xf zig-linux-x86_64-0.15.2.tar.xz -C /opt/
export PATH=/opt/zig-linux-x86_64-0.15.2:$PATH

# Clone and build
git clone https://github.com/blitz-gateway/blitz-gateway
cd blitz-gateway
zig build -Doptimize=ReleaseFast

# Create systemd service
sudo tee /etc/systemd/system/blitz-gateway.service > /dev/null <<EOF
[Unit]
Description=Blitz Edge Gateway
After=network.target

[Service]
Type=simple
User=blitz
Group=blitz
WorkingDirectory=/opt/blitz-gateway
ExecStart=/opt/blitz-gateway/zig-out/bin/blitz-gateway
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
sudo systemctl enable blitz-gateway
sudo systemctl start blitz-gateway
```

## Docker Production Deployment

### Multi-Environment Setup

```bash
# Directory structure
infra/
├── compose/
│   ├── common.yml      # Base configuration
│   ├── prod.yml        # Production overrides
│   └── monitoring.yml  # Observability stack
├── env/
│   └── env.prod        # Production environment
└── up.sh               # Smart deployment script

# Deploy production environment
./infra/up.sh prod up -d

# With monitoring
./infra/up.sh prod --profile monitoring up -d
```

### Production Docker Configuration

```yaml
# infra/compose/prod.yml
version: '3.8'

services:
  blitz-gateway:
    image: blitzgateway/blitz-quic:1.0.0
    deploy:
      mode: replicated
      replicas: 3
      resources:
        limits:
          cpus: '2.0'
          memory: 2G
        reservations:
          cpus: '1.0'
          memory: 1G
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
        window: 120s
    environment:
      - ENV=production
      - QUIC_LOG=error
      - GOMEMLIMIT=1GiB
    volumes:
      - ./certs:/app/certs:ro
      - ./config:/app/config:ro
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    networks:
      - blitz-network

networks:
  blitz-network:
    driver: overlay
    attachable: true
```

## Load Balancing & Scaling

### Horizontal Scaling

```yaml
# Docker Compose scaling
services:
  blitz-gateway:
    deploy:
      replicas: 5
      placement:
        constraints:
          - node.role == worker
      restart_policy:
        condition: on-failure

# Kubernetes HPA
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: blitz-gateway-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: blitz-gateway
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

### Load Balancer Configuration

```yaml
# NGINX upstream
upstream blitz_backend {
    least_conn;
    server blitz-gateway-1:8080 weight=1;
    server blitz-gateway-2:8080 weight=1;
    server blitz-gateway-3:8080 weight=1;
    keepalive 32;
}

server {
    listen 80;
    server_name your-domain.com;

    location / {
        proxy_pass http://blitz_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Session Affinity

For applications requiring sticky sessions:

```yaml
# Docker with session affinity
services:
  load-balancer:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
    depends_on:
      - blitz-gateway

# NGINX config with IP hashing
upstream blitz_backend {
    ip_hash;  # Session affinity
    server blitz-gateway-1:8080;
    server blitz-gateway-2:8080;
    server blitz-gateway-3:8080;
}
```

## Monitoring & Observability

### Full Monitoring Stack

```bash
# Deploy complete observability
make monitoring up -d

# Access dashboards
# Grafana: http://localhost:3000 (admin/admin)
# Prometheus: http://localhost:9090
# Node Exporter: http://localhost:9100
```

### Key Metrics to Monitor

```prometheus
# Request metrics
rate(blitz_http_requests_total[5m])
histogram_quantile(0.95, rate(blitz_http_request_duration_seconds_bucket[5m]))

# QUIC metrics
rate(blitz_quic_connections_total[5m])
blitz_quic_active_connections

# System metrics
rate(node_cpu_seconds_total{mode="idle"}[5m])
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes

# Error rates
rate(blitz_http_requests_total{status=~"5.."}[5m]) / rate(blitz_http_requests_total[5m])
```

### Alerting Rules

```yaml
# Prometheus alerting rules
groups:
  - name: blitz_gateway
    rules:
      - alert: HighErrorRate
        expr: rate(blitz_http_requests_total{status=~"5.."}[5m]) / rate(blitz_http_requests_total[5m]) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High error rate detected"

      - alert: HighLatency
        expr: histogram_quantile(0.95, rate(blitz_http_request_duration_seconds_bucket[5m])) > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High request latency detected"

      - alert: InstanceDown
        expr: up{job="blitz-gateway"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Blitz Gateway instance is down"
```

## Security Hardening

### TLS Configuration

```bash
# Generate certificates
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes

# Docker TLS setup
services:
  blitz-gateway:
    volumes:
      - ./certs/cert.pem:/app/certs/cert.pem:ro
      - ./certs/key.pem:/app/certs/key.pem:ro
    environment:
      - TLS_CERT_PATH=/app/certs/cert.pem
      - TLS_KEY_PATH=/app/certs/key.pem
```

### Let's Encrypt Automation

```bash
# Certbot for automatic certificates
certbot certonly --standalone -d your-domain.com

# Docker with certbot
services:
  certbot:
    image: certbot/certbot
    volumes:
      - ./certs:/etc/letsencrypt
    command: certonly --webroot --webroot-path=/var/www/html -d your-domain.com

  blitz-gateway:
    volumes:
      - ./certs/live/your-domain.com:/app/certs:ro
```

### Network Security

```bash
# iptables rules for Blitz Gateway
sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -A INPUT -p udp --dport 8443 -j ACCEPT
sudo iptables -A INPUT -j DROP

# Docker network isolation
networks:
  blitz-network:
    driver: overlay
    internal: true  # No external access
    ipam:
      config:
        - subnet: 172.20.0.0/16
```

### Secrets Management

```yaml
# Kubernetes secrets
apiVersion: v1
kind: Secret
metadata:
  name: blitz-gateway-secrets
type: Opaque
data:
  tls.crt: LS0tLS1CRUdJTi...
  tls.key: LS0tLS1CRUdJTi...
  jwt.secret: c2VjcmV0X2tleQ==

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blitz-gateway
spec:
  template:
    spec:
      containers:
      - name: blitz-gateway
        env:
        - name: JWT_SECRET
          valueFrom:
            secretKeyRef:
              name: blitz-gateway-secrets
              key: jwt.secret
        volumeMounts:
        - name: tls-certs
          mountPath: /app/certs
      volumes:
      - name: tls-certs
        secret:
          secretName: blitz-gateway-secrets
          items:
          - key: tls.crt
            path: cert.pem
          - key: tls.key
            path: key.pem
```

## Performance Tuning

### System Optimization

```bash
# Kernel parameters for high performance
sudo tee /etc/sysctl.d/99-blitz.conf > /dev/null <<EOF
# Network tuning
net.core.somaxconn = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.ip_local_port_range = 1024 65535

# Memory management
vm.swappiness = 10
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5

# File descriptors
fs.file-max = 2097152
EOF

sudo sysctl -p /etc/sysctl.d/99-blitz.conf
```

### Docker Performance

```yaml
services:
  blitz-gateway:
    deploy:
      resources:
        limits:
          cpus: '4.0'
          memory: 8G
        reservations:
          cpus: '2.0'
          memory: 4G
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
      nproc:
        soft: 65536
        hard: 65536
    cap_add:
      - SYS_NICE
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
```

### Application Tuning

```bash
# Environment variables for performance
export QUIC_MAX_CONNECTIONS=10000
export HTTP_MAX_CONCURRENT=1000
export WORKER_THREADS=8
export BUFFER_SIZE=65536

# Runtime configuration
{
  "server": {
    "workers": 8,
    "max_connections": 10000,
    "buffer_size": 65536,
    "timeout": 30
  },
  "quic": {
    "max_idle_timeout": 30,
    "max_streams": 100,
    "initial_max_data": 1048576
  }
}
```

## Backup & Recovery

### Configuration Backup

```bash
#!/bin/bash
# Backup script

BACKUP_DIR="/opt/blitz-gateway/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create backup directory
mkdir -p $BACKUP_DIR

# Backup configuration
tar -czf $BACKUP_DIR/config_$TIMESTAMP.tar.gz \
    /opt/blitz-gateway/config/ \
    /opt/blitz-gateway/certs/

# Backup Docker volumes
docker run --rm -v blitz_gateway_data:/data -v $BACKUP_DIR:/backup \
    alpine tar czf /backup/data_$TIMESTAMP.tar.gz -C / data

# Rotate backups (keep last 7 days)
find $BACKUP_DIR -name "*.tar.gz" -mtime +7 -delete

echo "Backup completed: $TIMESTAMP"
```

### Disaster Recovery

```bash
#!/bin/bash
# Recovery script

BACKUP_FILE=$1

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup_file>"
    exit 1
fi

# Stop services
docker-compose down

# Restore configuration
tar -xzf $BACKUP_FILE -C /opt/blitz-gateway/

# Restore data volumes
docker run --rm -v blitz_gateway_data:/data -v $(dirname $BACKUP_FILE):/backup \
    alpine tar xzf /backup/$(basename $BACKUP_FILE) -C /

# Start services
docker-compose up -d

echo "Recovery completed"
```

### Automated Backups

```yaml
# Kubernetes CronJob for backups
apiVersion: batch/v1
kind: CronJob
metadata:
  name: blitz-gateway-backup
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: alpine
            command:
            - /bin/sh
            - -c
            - |
              apk add --no-cache postgresql-client
              pg_dump -h postgres -U blitz blitz_db > /backup/backup.sql
              gzip /backup/backup.sql
            volumeMounts:
            - name: backup-storage
              mountPath: /backup
          volumes:
          - name: backup-storage
            persistentVolumeClaim:
              claimName: backup-pvc
          restartPolicy: OnFailure
```

## Troubleshooting

### Common Issues

#### High CPU Usage

```bash
# Check system load
top -H

# Check Blitz Gateway threads
ps -T -p $(pgrep blitz-gateway)

# Profile with perf
sudo perf record -F 99 -p $(pgrep blitz-gateway) -g -- sleep 60
sudo perf report

# Check for thread leaks
watch 'ps -T -C blitz-gateway | wc -l'
```

#### Memory Leaks

```bash
# Monitor memory usage
watch 'ps aux --sort=-%mem | head -10'

# Check for memory growth
valgrind --tool=massif zig-out/bin/blitz-gateway

# Heap profiling
export MALLOC_TRACE=/tmp/malloc.trace
zig-out/bin/blitz-gateway &
mtrace /tmp/malloc.trace
```

#### Network Issues

```bash
# Check network connections
netstat -tunlp | grep :8443

# Monitor QUIC connections
ss -tunlp | grep blitz

# Packet capture
tcpdump -i any udp port 8443 -w capture.pcap

# Check firewall rules
sudo iptables -L -n
sudo ufw status
```

#### Docker Issues

```bash
# Check container logs
docker logs blitz-gateway

# Check container resource usage
docker stats blitz-gateway

# Debug container
docker run -it --entrypoint /bin/bash blitzgateway/blitz-quic

# Check Docker daemon
sudo systemctl status docker
journalctl -u docker -f
```

### Performance Benchmarks

```bash
# HTTP load testing
hey -n 100000 -c 100 http://localhost:8080/

# QUIC performance testing
qperf -c localhost:8443 -t 60

# Memory profiling
heaptrack zig-out/bin/blitz-gateway

# CPU profiling
perf stat zig-out/bin/blitz-gateway
```

### Log Analysis

```bash
# Parse error logs
grep "ERROR" /var/log/blitz-gateway/*.log | tail -20

# Monitor request patterns
tail -f /var/log/blitz-gateway/access.log | awk '{print $7}' | sort | uniq -c | sort -nr

# Check for anomalies
journalctl -u blitz-gateway -f | grep -i "error\|warn\|fail"
```

### Health Checks

```bash
# Basic health check
curl -f http://localhost:8080/health

# Detailed health check
curl http://localhost:8080/metrics | grep blitz_health

# Kubernetes readiness
kubectl exec -it deployment/blitz-gateway -- wget --quiet --tries=1 --spider http://localhost:8080/health
```

## Support & Resources

### Getting Help

1. **Documentation**: Check this guide first
2. **GitHub Issues**: Report bugs and request features
3. **Community**: Join discussions on GitHub Discussions
4. **Professional Support**: Contact the core team for enterprise support

### Useful Commands

```bash
# Quick status check
make prod ps
make prod logs -f

# Emergency restart
make prod restart

# Full system reset
make prod down
make prod up -d

# Performance monitoring
docker stats $(docker ps -q --filter name=blitz)
```

### Maintenance Schedule

- **Daily**: Check logs and metrics
- **Weekly**: Update Docker images, rotate logs
- **Monthly**: Security patches, performance tuning
- **Quarterly**: Major version upgrades, capacity planning

---

**Ready for production?** Blitz Gateway is designed for high-performance edge computing. Follow this guide for reliable, scalable deployments. 🚀
