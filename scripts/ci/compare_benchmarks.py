#!/usr/bin/env python3

"""
scripts/ci/compare_benchmarks.py

Compare performance benchmarks and detect regressions
"""

import json
import sys
import argparse
from typing import Dict, Any, List


def load_benchmark(path: str) -> Dict[str, Any]:
    """Load benchmark results"""
    with open(path, 'r') as f:
        return json.load(f)


def compare_metrics(base: float, current: float, metric_name: str) -> Dict[str, Any]:
    """Compare a single metric"""
    # For latency/time metrics, lower is better
    # For throughput/RPS metrics, higher is better
    
    is_inverse_metric = any(x in metric_name.lower() for x in ['latency', 'time', 'duration'])
    
    if is_inverse_metric:
        change_pct = ((current - base) / base) * 100
        improved = current < base
    else:
        change_pct = ((current - base) / base) * 100
        improved = current > base
    
    return {
        'metric': metric_name,
        'base': base,
        'current': current,
        'change_pct': round(change_pct, 2),
        'improved': improved,
        'regression': not improved and abs(change_pct) > 5
    }


def generate_report(comparisons: List[Dict[str, Any]], threshold: float) -> str:
    """Generate markdown report"""
    report = []
    report.append("| Metric | Base | Current | Change | Status |")
    report.append("|--------|------|---------|--------|--------|")
    
    has_regression = False
    
    for comp in comparisons:
        metric = comp['metric']
        base = comp['base']
        current = comp['current']
        change = comp['change_pct']
        
        if comp['improved']:
            status = f"✅ +{abs(change):.1f}%"
        elif comp['regression']:
            status = f"❌ -{abs(change):.1f}%"
            has_regression = True
        else:
            status = f"➡️ {change:+.1f}%"
        
        report.append(f"| {metric} | {base:.2f} | {current:.2f} | {change:+.1f}% | {status} |")
    
    return '\n'.join(report), has_regression


def main():
    parser = argparse.ArgumentParser(description='Compare benchmarks')
    parser.add_argument('--base', required=True, help='Base benchmark file')
    parser.add_argument('--current', required=True, help='Current benchmark file')
    parser.add_argument('--threshold', type=float, default=5.0, 
                       help='Regression threshold percentage')
    parser.add_argument('--output', required=True, help='Output markdown file')
    args = parser.parse_args()
    
    base = load_benchmark(args.base)
    current = load_benchmark(args.current)
    
    comparisons = []
    
    # Compare common metrics
    metrics = set(base.keys()) & set(current.keys())
    
    for metric in metrics:
        if isinstance(base[metric], (int, float)) and isinstance(current[metric], (int, float)):
            comparisons.append(compare_metrics(base[metric], current[metric], metric))
    
    report, has_regression = generate_report(comparisons, args.threshold)
    
    # Write report
    with open(args.output, 'w') as f:
        f.write(report)
    
    # Write JSON summary
    with open('perf-comparison.json', 'w') as f:
        json.dump({
            'regression': has_regression,
            'comparisons': comparisons
        }, f, indent=2)
    
    print(report)
    
    if has_regression:
        print(f"\n❌ Performance regression detected (threshold: {args.threshold}%)")
        sys.exit(1)
    else:
        print(f"\n✅ No performance regression (threshold: {args.threshold}%)")
        sys.exit(0)


if __name__ == '__main__':
    main()

