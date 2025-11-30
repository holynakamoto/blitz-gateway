#!/usr/bin/env bash

# Blitz Gateway Docker Compose Wrapper Script
# Handles multiple environments with proper isolation

set -euo pipefail

# Default to development environment
ENV=${1:-dev}
PROJECT="blitz-${ENV}"

# Remove environment name from arguments
shift || true

# Configure environment-specific settings
case "$ENV" in
  dev)
    COMPOSE_FILES=("common.yml" "dev.yml")
    ENV_FILE="env/env.dev"
    ;;
  staging)
    COMPOSE_FILES=("common.yml" "staging.yml")
    ENV_FILE="env/env.staging"
    ;;
  prod)
    COMPOSE_FILES=("common.yml" "prod.yml")
    ENV_FILE="env/env.prod"
    ;;
  ci)
    COMPOSE_FILES=("common.yml" "ci.yml")
    ENV_FILE="env/env.ci"
    ;;
  monitoring)
    COMPOSE_FILES=("common.yml" "monitoring.yml")
    ENV_FILE="env/env.dev"
    ;;
  *)
    echo "❌ Unknown environment: $ENV"
    echo "Available environments: dev, staging, prod, ci, monitoring"
    exit 1
    ;;
esac

# Build docker compose command
COMPOSE_ARGS=()
for file in "${COMPOSE_FILES[@]}"; do
  COMPOSE_ARGS+=(-f "$PWD/infra/compose/$file")
done

# Add environment file if it exists
if [[ -f "$PWD/infra/env/$ENV_FILE" ]]; then
  COMPOSE_ARGS+=(--env-file "$PWD/infra/env/$ENV_FILE")
fi

# Set project name for isolation
export COMPOSE_PROJECT_NAME="$PROJECT"

echo "🚀 Starting Blitz Gateway ($ENV environment)"
echo "   Project: $PROJECT"
echo "   Files: ${COMPOSE_FILES[*]}"
echo "   Env file: $ENV_FILE"
echo ""

# Execute docker compose with all arguments
exec docker compose "${COMPOSE_ARGS[@]}" "$@"
