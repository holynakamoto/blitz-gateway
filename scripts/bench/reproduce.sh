#!/bin/bash
# Blitz Gateway Benchmark Reproducer
# Reproduce and compare benchmark results across different versions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
BENCH_DIR="$PROJECT_ROOT/benches"
RESULTS_DIR="$BENCH_DIR/results"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
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

# Show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] COMMAND

Reproduce and compare Blitz Gateway benchmark results.

COMMANDS:
    run [COMMIT]     Run benchmark for current commit or specified commit
    compare COMMIT1 COMMIT2  Compare results between two commits
    list             List all benchmark results
    baseline         Set current results as performance baseline
    regression       Check for performance regression vs baseline

OPTIONS:
    -h, --help       Show this help message
    -d, --duration   Benchmark duration in seconds (default: 30)
    -c, --connections Number of concurrent connections (default: 100)
    -t, --threads    Number of threads (default: auto)
    --tls            Enable TLS testing
    --quic           Enable QUIC testing
    --json           Output results in JSON format

EXAMPLES:
    $0 run                    # Run benchmark for current commit
    $0 run abc123             # Run benchmark for specific commit
    $0 compare abc123 def456  # Compare two commits
    $0 list                   # List all results
    $0 baseline               # Set current as baseline
    $0 regression             # Check for regressions

EOF
}

# Parse command line arguments
parse_args() {
    COMMAND=""
    COMMIT1=""
    COMMIT2=""
    DURATION=30
    CONNECTIONS=100
    THREADS=""
    TLS=false
    QUIC=false
    JSON=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -d|--duration)
                DURATION="$2"
                shift 2
                ;;
            -c|--connections)
                CONNECTIONS="$2"
                shift 2
                ;;
            -t|--threads)
                THREADS="$2"
                shift 2
                ;;
            --tls)
                TLS=true
                shift
                ;;
            --quic)
                QUIC=true
                shift
                ;;
            --json)
                JSON=true
                shift
                ;;
            run|compare|list|baseline|regression)
                if [ -z "$COMMAND" ]; then
                    COMMAND="$1"
                else
                    log_error "Multiple commands specified"
                    exit 1
                fi
                shift
                ;;
            *)
                if [ -z "$COMMIT1" ]; then
                    COMMIT1="$1"
                elif [ -z "$COMMIT2" ]; then
                    COMMIT2="$1"
                else
                    log_error "Too many arguments"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Set default threads if not specified
    if [ -z "$THREADS" ]; then
        THREADS=$(nproc)
    fi

    # Validate command
    if [ -z "$COMMAND" ]; then
        log_error "No command specified"
        usage
        exit 1
    fi
}

# Check if we're in a git repository
check_git_repo() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Not in a git repository"
        exit 1
    fi
}

# Get current commit hash
get_current_commit() {
    git rev-parse HEAD
}

# Get commit info
get_commit_info() {
    local commit="$1"
    local info
    info=$(git show --no-patch --format="%H %s" "$commit" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_error "Invalid commit: $commit"
        exit 1
    fi
    echo "$info"
}

# Switch to specific commit
switch_to_commit() {
    local commit="$1"
    log_info "Switching to commit: $commit"

    # Stash any uncommitted changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
        log_warning "Stashing uncommitted changes..."
        git stash push -m "benchmark-reproduce-$(date +%s)"
        STASHED=true
    fi

    # Checkout commit
    git checkout "$commit"

    # Rebuild if needed
    if [ ! -f "zig-out/bin/blitz" ] || [ "zig-out/bin/blitz" -ot "build.zig" ]; then
        log_info "Rebuilding binary..."
        zig build -Doptimize=ReleaseFast
    fi
}

# Restore original state
restore_state() {
    if [ "${STASHED:-false}" = true ]; then
        log_info "Restoring stashed changes..."
        git stash pop
    fi

    # Switch back to original branch if needed
    if [ -n "${ORIGINAL_BRANCH:-}" ]; then
        git checkout "$ORIGINAL_BRANCH"
    fi
}

# Run benchmark for a specific commit
run_benchmark() {
    local commit="$1"
    local commit_info
    local results_dir

    # Get commit info
    if [ "$commit" = "HEAD" ] || [ "$commit" = "$(get_current_commit)" ]; then
        commit_info="$(get_current_commit) $(git log -1 --format=%s)"
        results_dir="$RESULTS_DIR/$(get_current_commit)"
    else
        commit_info="$(get_commit_info "$commit")"
        results_dir="$RESULTS_DIR/$commit"
    fi

    log_info "Running benchmark for: $commit_info"

    # Create results directory
    mkdir -p "$results_dir"

    # Set environment variables for benchmark
    export DURATION="$DURATION"
    export CONNECTIONS="$CONNECTIONS"
    export THREADS="$THREADS"
    export TLS="$TLS"
    export QUIC="$QUIC"

    # Run the benchmark
    if "$SCRIPT_DIR/local-benchmark.sh"; then
        # Move results to commit-specific directory
        if [ -d "$BENCH_DIR/results/$(date +%Y%m%d_%H%M%S)" ]; then
            mv "$BENCH_DIR/results/$(date +%Y%m%d_%H%M%S)"/* "$results_dir/" 2>/dev/null || true
            rmdir "$BENCH_DIR/results/$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        fi

        # Save commit info
        echo "$commit_info" > "$results_dir/commit.txt"
        echo "Duration: $DURATION" >> "$results_dir/commit.txt"
        echo "Connections: $CONNECTIONS" >> "$results_dir/commit.txt"
        echo "Threads: $THREADS" >> "$results_dir/commit.txt"
        echo "TLS: $TLS" >> "$results_dir/commit.txt"
        echo "QUIC: $QUIC" >> "$results_dir/commit.txt"

        log_success "Benchmark completed for $commit"
        return 0
    else
        log_error "Benchmark failed for $commit"
        return 1
    fi
}

# List all benchmark results
list_results() {
    log_info "Available benchmark results:"

    if [ ! -d "$RESULTS_DIR" ]; then
        log_warning "No benchmark results found"
        return
    fi

    local count=0
    for result_dir in "$RESULTS_DIR"/*/; do
        if [ -d "$result_dir" ] && [ -f "$result_dir/commit.txt" ]; then
            local commit_info
            commit_info=$(head -1 "$result_dir/commit.txt")
            local summary_file="$result_dir/summary.txt"

            echo "----------------------------------------"
            echo "Commit: $(basename "$result_dir")"
            echo "Info: $commit_info"

            if [ -f "$summary_file" ]; then
                echo "Summary:"
                grep -E "(Requests/sec|Latency|Duration)" "$summary_file" | head -3 || true
            fi

            count=$((count + 1))
        fi
    done

    if [ $count -eq 0 ]; then
        log_warning "No valid benchmark results found"
    else
        echo "----------------------------------------"
        log_success "Found $count benchmark result(s)"
    fi
}

# Compare two commits
compare_commits() {
    local commit1="$1"
    local commit2="$2"
    local dir1="$RESULTS_DIR/$commit1"
    local dir2="$RESULTS_DIR/$commit2"

    # Check if results exist
    if [ ! -d "$dir1" ]; then
        log_error "No results found for commit: $commit1"
        return 1
    fi

    if [ ! -d "$dir2" ]; then
        log_error "No results found for commit: $commit2"
        return 1
    fi

    log_info "Comparing $commit1 vs $commit2"

    # Get commit info
    local info1 info2
    info1=$(head -1 "$dir1/commit.txt")
    info2=$(head -1 "$dir2/commit.txt")

    echo "========================================"
    echo "Benchmark Comparison"
    echo "========================================"
    echo "Commit 1: $info1"
    echo "Commit 2: $info2"
    echo "========================================"

    # Compare key metrics
    compare_metric "WRK Results" "$dir1/wrk_results.txt" "$dir2/wrk_results.txt" "Req/Sec"
    compare_metric "hey Results" "$dir1/hey_results.txt" "$dir2/hey_results.txt" "Requests/sec"

    echo "========================================"
}

# Compare a specific metric between two result files
compare_metric() {
    local label="$1"
    local file1="$2"
    local file2="$3"
    local pattern="$4"

    if [ -f "$file1" ] && [ -f "$file2" ]; then
        local val1 val2
        val1=$(grep "$pattern" "$file1" | head -1 | sed 's/.*: //' | sed 's/[^0-9.]*//g')
        val2=$(grep "$pattern" "$file2" | head -1 | sed 's/.*: //' | sed 's/[^0-9.]*//g')

        if [ -n "$val1" ] && [ -n "$val2" ]; then
            local diff
            diff=$(echo "scale=2; $val2 - $val1" | bc 2>/dev/null || echo "0")

            echo "$label:"
            echo "  Commit 1: $val1"
            echo "  Commit 2: $val2"
            echo "  Difference: $diff"

            # Color code the difference
            if (( $(echo "$diff < -10" | bc -l 2>/dev/null || echo "0") )); then
                echo -e "  Status: ${RED}REGRESSION${NC}"
            elif (( $(echo "$diff > 10" | bc -l 2>/dev/null || echo "0") )); then
                echo -e "  Status: ${GREEN}IMPROVEMENT${NC}"
            else
                echo -e "  Status: ${YELLOW}NEUTRAL${NC}"
            fi
            echo ""
        fi
    fi
}

# Set performance baseline
set_baseline() {
    local current_commit
    current_commit=$(get_current_commit)
    local baseline_file="$BENCH_DIR/baseline.txt"

    log_info "Setting performance baseline to current commit: $current_commit"

    # Run benchmark if not already done
    if [ ! -d "$RESULTS_DIR/$current_commit" ]; then
        log_info "Running benchmark for baseline..."
        run_benchmark "$current_commit"
    fi

    # Set as baseline
    echo "$current_commit" > "$baseline_file"
    log_success "Baseline set to: $current_commit"
}

# Check for performance regression
check_regression() {
    local baseline_file="$BENCH_DIR/baseline.txt"

    if [ ! -f "$baseline_file" ]; then
        log_error "No baseline set. Run '$0 baseline' first."
        return 1
    fi

    local baseline_commit
    baseline_commit=$(cat "$baseline_file")
    local current_commit
    current_commit=$(get_current_commit)

    if [ "$baseline_commit" = "$current_commit" ]; then
        log_info "Current commit is the baseline - no regression to check"
        return 0
    fi

    log_info "Checking for regression vs baseline: $baseline_commit"

    # Run benchmark for current commit if needed
    if [ ! -d "$RESULTS_DIR/$current_commit" ]; then
        run_benchmark "$current_commit"
    fi

    # Compare with baseline
    compare_commits "$baseline_commit" "$current_commit"

    # Check for significant regressions
    local wrk_file="$RESULTS_DIR/$current_commit/wrk_results.txt"
    local baseline_wrk="$RESULTS_DIR/$baseline_commit/wrk_results.txt"

    if [ -f "$wrk_file" ] && [ -f "$baseline_wrk" ]; then
        local current_rps baseline_rps
        current_rps=$(grep "Requests/sec:" "$wrk_file" | sed 's/.*: //' | sed 's/[^0-9.]*//g')
        baseline_rps=$(grep "Requests/sec:" "$baseline_wrk" | sed 's/.*: //' | sed 's/[^0-9.]*//g')

        if [ -n "$current_rps" ] && [ -n "$baseline_rps" ]; then
            local degradation
            degradation=$(echo "scale=2; ($baseline_rps - $current_rps) / $baseline_rps * 100" | bc -l 2>/dev/null)

            if (( $(echo "$degradation > 10" | bc -l 2>/dev/null || echo "0") )); then
                log_error "PERFORMANCE REGRESSION DETECTED: ${degradation}% degradation in requests/sec"
                echo "Current: ${current_rps} req/sec"
                echo "Baseline: ${baseline_rps} req/sec"
                return 1
            else
                log_success "No significant performance regression detected"
            fi
        fi
    fi
}

# Main function
main() {
    parse_args "$@"
    check_git_repo

    # Save original branch
    ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    STASHED=false

    # Set up cleanup
    trap restore_state EXIT INT TERM

    case "$COMMAND" in
        run)
            if [ -n "$COMMIT1" ]; then
                switch_to_commit "$COMMIT1"
                run_benchmark "$COMMIT1"
            else
                run_benchmark "$(get_current_commit)"
            fi
            ;;
        compare)
            if [ -z "$COMMIT1" ] || [ -z "$COMMIT2" ]; then
                log_error "compare command requires two commit arguments"
                exit 1
            fi
            compare_commits "$COMMIT1" "$COMMIT2"
            ;;
        list)
            list_results
            ;;
        baseline)
            set_baseline
            ;;
        regression)
            check_regression
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"