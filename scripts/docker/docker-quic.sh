#!/bin/bash
# Docker script for QUIC testing
# Usage: ./scripts/docker-quic.sh [build|run|stop|logs|test|shell|rebuild]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}❌ Docker is not running${NC}"
    echo "Please start Docker Desktop and try again"
    exit 1
fi

ACTION="${1:-run}"

case "$ACTION" in
    build)
        echo -e "${BLUE}🔨 Building Docker image...${NC}"
        docker-compose build
        echo -e "${GREEN}✅ Build complete!${NC}"
        ;;
    
    run)
        echo -e "${BLUE}🚀 Starting QUIC server in Docker...${NC}"
        
        # Create certs if they don't exist
        if [ ! -f "certs/server.crt" ] || [ ! -f "certs/server.key" ]; then
            echo -e "${YELLOW}📜 Creating self-signed certificates...${NC}"
            mkdir -p certs
            if command -v openssl &> /dev/null; then
                openssl req -x509 -newkey rsa:4096 \
                  -keyout certs/server.key \
                  -out certs/server.crt \
                  -days 365 -nodes \
                  -subj "/CN=localhost" 2>/dev/null || {
                    echo -e "${RED}⚠️  Failed to create certificates${NC}"
                    echo "   Install: brew install openssl"
                }
            else
                echo -e "${YELLOW}⚠️  OpenSSL not found, certificates not created${NC}"
                echo "   Install: brew install openssl"
            fi
        fi
        
        # Stop existing container
        docker-compose down 2>/dev/null || true
        
        # Start server
        docker-compose up -d blitz-quic
        
        # Wait for server to start
        echo -e "${YELLOW}⏳ Waiting for server to start...${NC}"
        sleep 3
        
        # Check if container is running
        if ! docker ps | grep -q blitz-quic-server; then
            echo -e "${RED}❌ Container failed to start${NC}"
            echo -e "${YELLOW}Checking logs...${NC}"
            docker-compose logs blitz-quic
            exit 1
        fi
        
        echo -e "${GREEN}✅ QUIC server running in Docker${NC}"
        echo ""
        echo "Container: blitz-quic-server"
        echo "Ports:"
        echo "  - UDP 8443: QUIC"
        echo "  - TCP 8080: HTTP"
        echo "  - TCP 8444: HTTPS"
        echo ""
        echo -e "${BLUE}Test with:${NC}"
        echo "  curl --http3-only -k https://localhost:8443/hello"
        echo ""
        echo -e "${BLUE}View logs:${NC}"
        echo "  ./scripts/docker-quic.sh logs"
        echo ""
        echo -e "${BLUE}Stop server:${NC}"
        echo "  ./scripts/docker-quic.sh stop"
        ;;
    
    stop)
        echo -e "${YELLOW}🛑 Stopping QUIC server...${NC}"
        docker-compose down
        echo -e "${GREEN}✅ Server stopped${NC}"
        ;;
    
    logs)
        echo -e "${BLUE}📋 QUIC server logs (Ctrl+C to exit):${NC}"
        docker-compose logs -f blitz-quic
        ;;
    
    test)
        echo -e "${BLUE}🧪 Testing QUIC server...${NC}"
        
        # Check if server is running
        if ! docker ps | grep -q blitz-quic-server; then
            echo -e "${RED}❌ Server is not running. Start it with: ./scripts/docker-quic.sh run${NC}"
            exit 1
        fi
        
        # Test UDP port
        echo "1. Testing UDP port 8443..."
        if nc -zu localhost 8443 2>/dev/null; then
            echo -e "   ${GREEN}✅ UDP port is open${NC}"
        else
            echo -e "   ${YELLOW}⚠️  UDP port check failed (may be normal for QUIC)${NC}"
        fi
        
        # Test with curl (if available)
        if command -v curl &> /dev/null; then
            echo "2. Testing with curl --http3-only..."
            if curl --version | grep -q "HTTP3"; then
                curl --http3-only -k -v https://localhost:8443/hello 2>&1 | head -20 || {
                    echo -e "   ${YELLOW}⚠️  curl test failed (server may still be starting)${NC}"
                }
            else
                echo -e "   ${YELLOW}⚠️  curl doesn't support HTTP/3${NC}"
                echo "   Install newer curl: brew upgrade curl"
            fi
        else
            echo "2. curl not found, skipping HTTP/3 test"
        fi
        
        echo ""
        echo -e "${GREEN}✅ Test complete${NC}"
        ;;
    
    shell)
        echo -e "${BLUE}🐚 Opening shell in container...${NC}"
        docker-compose exec blitz-quic /bin/bash || \
        docker exec -it blitz-quic-server /bin/bash
        ;;
    
    rebuild)
        echo -e "${BLUE}🔄 Rebuilding and restarting...${NC}"
        docker-compose down
        docker-compose build --no-cache
        docker-compose up -d blitz-quic
        echo -e "${GREEN}✅ Rebuild complete${NC}"
        ;;
    
    *)
        echo "Usage: $0 [build|run|stop|logs|test|shell|rebuild]"
        echo ""
        echo "Commands:"
        echo "  build   - Build Docker image"
        echo "  run     - Start QUIC server (default)"
        echo "  stop    - Stop QUIC server"
        echo "  logs    - View server logs"
        echo "  test    - Run connectivity tests"
        echo "  shell   - Open shell in container"
        echo "  rebuild - Rebuild image and restart"
        exit 1
        ;;
esac
