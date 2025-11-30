# Blitz Gateway Development Makefile
# Provides convenient shortcuts for common development tasks

.PHONY: help dev staging prod ci monitoring test build clean

# Default target
help:
	@echo "🚀 Blitz Gateway Development Commands"
	@echo ""
	@echo "Environments:"
	@echo "  make dev         - Start development environment"
	@echo "  make staging     - Start staging environment"
	@echo "  make prod        - Start production environment"
	@echo "  make ci          - Start CI environment"
	@echo ""
	@echo "Monitoring:"
	@echo "  make monitoring  - Start monitoring stack"
	@echo ""
	@echo "Development:"
	@echo "  make test        - Run all tests"
	@echo "  make build       - Build production binary"
	@echo "  make clean       - Clean up containers and volumes"
	@echo ""
	@echo "Examples:"
	@echo "  make dev logs    - View development logs"
	@echo "  make staging ps  - Check staging status"
	@echo "  make prod scale REPLICAS=5  - Scale production"

# Environment targets
dev:
	./infra/up.sh dev $(filter-out $@,$(MAKECMDGOALS))

staging:
	./infra/up.sh staging $(filter-out $@,$(MAKECMDGOALS))

prod:
	./infra/up.sh prod $(filter-out $@,$(MAKECMDGOALS))

ci:
	./infra/up.sh ci $(filter-out $@,$(MAKECMDGOALS))

monitoring:
	./infra/up.sh monitoring $(filter-out $@,$(MAKECMDGOALS))

# Development helpers
test:
	zig build test

build:
	zig build -Doptimize=ReleaseFast

# Cleanup
clean:
	@echo "🧹 Cleaning up all environments..."
	-./infra/up.sh dev down -v --remove-orphans 2>/dev/null || true
	-./infra/up.sh staging down -v --remove-orphans 2>/dev/null || true
	-./infra/up.sh prod down -v --remove-orphans 2>/dev/null || true
	-./infra/up.sh ci down -v --remove-orphans 2>/dev/null || true
	-docker system prune -f

# Allow passing arguments to docker-compose commands
%:
	@: