#!/bin/bash
# Blitz Gateway VM Benchmark Runner
# Quick setup and execution of benchmarks in Vagrant VM

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_nuclear() {
    echo -e "${PURPLE}[NUCLEAR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "🔍 Checking prerequisites..."

    # Check Vagrant
    if ! command -v vagrant &> /dev/null; then
        log_error "Vagrant not found. Install from: https://www.vagrantup.com/"
        exit 1
    fi

    # Check VirtualBox
    if ! command -v VBoxManage &> /dev/null; then
        log_error "VirtualBox not found. Install from: https://www.virtualbox.org/"
        exit 1
    fi

    log_success "✅ Prerequisites satisfied"
}

# Setup VM if needed
setup_vm() {
    log_info "🚀 Setting up Blitz Gateway nuclear benchmark VM..."

    # Check if VM exists
    if vagrant status | grep -q "not created"; then
        log_info "Creating new VM (this may take 10-20 minutes)..."
        vagrant up
    else
        log_info "VM already exists, starting..."
        vagrant up
    fi

    log_success "✅ VM is ready"
}

# Run basic benchmarks
run_basic_benchmarks() {
    log_info "🏃 Running basic HTTP benchmarks in VM..."

    vagrant ssh -c "
        cd /vagrant
        echo 'Building Blitz Gateway...'
        zig build -Doptimize=ReleaseFast

        echo 'Starting server...'
        ./zig-out/bin/blitz &
        SERVER_PID=\$!

        sleep 3

        echo 'Running basic benchmarks...'
        ./scripts/bench/local-benchmark.sh

        echo 'Stopping server...'
        kill \$SERVER_PID 2>/dev/null || true

        echo 'Basic benchmarks complete!'
    "

    log_success "✅ Basic benchmarks completed"
}

# Run nuclear benchmarks
run_nuclear_benchmarks() {
    log_nuclear "💥 Running NUCLEAR benchmarks in VM..."

    vagrant ssh -c "
        cd /vagrant
        echo 'Building optimized Blitz Gateway...'
        zig build -Doptimize=ReleaseFast

        echo '🚀 Starting nuclear WRK2 benchmark (10M+ RPS target)...'
        ./nuclear-benchmarks/scripts/nuclear-wrk2.sh

        echo '🎯 Nuclear benchmarks complete!'
    "

    log_success "✅ Nuclear benchmarks completed"
}

# Run Docker nuclear environment
run_docker_nuclear() {
    log_nuclear "🐳 Running Docker nuclear environment..."

    vagrant ssh -c "
        cd /vagrant/nuclear-benchmarks/docker
        echo 'Starting nuclear Docker environment...'
        docker-compose -f docker-compose.nuclear.yml up -d

        echo 'Running complete nuclear suite...'
        docker-compose -f docker-compose.nuclear.yml exec -T nuclear-benchmarks \\
            /nuclear-benchmarks/run-nuclear-suite.sh

        echo 'Nuclear Docker environment complete!'
    "

    log_success "✅ Docker nuclear environment completed"
}

# Show results
show_results() {
    log_info "📊 Benchmark results:"

    echo ""
    echo "=========================================="
    echo "BENCHMARK RESULTS SUMMARY"
    echo "=========================================="

    # Show latest results
    if [ -d "benches/results" ]; then
        echo "Latest benchmark runs:"
        ls -la benches/results/ | tail -5

        echo ""
        echo "Most recent results:"
        LATEST_DIR=$(ls -td benches/results/*/ 2>/dev/null | head -1 || echo "")
        if [ -n "$LATEST_DIR" ] && [ -f "$LATEST_DIR/summary.txt" ]; then
            echo "----------------------------------------"
            cat "$LATEST_DIR/summary.txt"
            echo "----------------------------------------"
        fi
    else
        echo "No results found. Run benchmarks first."
    fi

    echo ""
    echo "View full results in VM:"
    echo "  vagrant ssh"
    echo "  results"
    echo ""
}

# Main menu
show_menu() {
    echo ""
    echo "=========================================="
    echo "🚀 BLITZ GATEWAY VM BENCHMARK RUNNER"
    echo "=========================================="
    echo "Choose benchmark type:"
    echo "1) Basic HTTP benchmarks (quick validation)"
    echo "2) Nuclear WRK2 benchmarks (10M+ RPS target)"
    echo "3) Docker nuclear environment (full suite)"
    echo "4) Show results"
    echo "5) Access VM shell"
    echo "6) Stop VM"
    echo "7) Destroy VM"
    echo "q) Quit"
    echo ""
    read -p "Choice (1-7,q): " choice
    echo ""
}

# Main function
main() {
    echo "=========================================="
    echo "🚀 BLITZ GATEWAY VM BENCHMARK SUITE"
    echo "=========================================="
    echo "Nuclear-grade HTTP proxy performance testing"
    echo ""

    check_prerequisites

    while true; do
        show_menu

        case $choice in
            1)
                setup_vm
                run_basic_benchmarks
                show_results
                ;;
            2)
                setup_vm
                run_nuclear_benchmarks
                show_results
                ;;
            3)
                setup_vm
                run_docker_nuclear
                show_results
                ;;
            4)
                show_results
                ;;
            5)
                log_info "Accessing VM shell (exit with Ctrl+D)..."
                vagrant ssh || true
                ;;
            6)
                log_info "Stopping VM..."
                vagrant halt
                log_success "VM stopped"
                ;;
            7)
                read -p "Are you sure you want to destroy the VM? (y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    log_warning "Destroying VM..."
                    vagrant destroy -f
                    log_success "VM destroyed"
                fi
                ;;
            q|Q)
                echo "Goodbye! 🚀"
                exit 0
                ;;
            *)
                log_warning "Invalid choice. Please select 1-7 or q."
                ;;
        esac

        echo ""
        read -p "Press Enter to continue..."
    done
}

# Run main function with all arguments
main "$@"
