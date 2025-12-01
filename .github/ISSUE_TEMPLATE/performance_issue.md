---
name: Performance Issue
about: Report performance degradation or optimization opportunity
title: '[PERF] '
labels: performance
assignees: ''
---

## Performance Issue Description

<!-- Describe the performance problem -->



## Current Performance

<!-- Provide current metrics -->

- **Throughput**: 
- **Latency (p50/p99/p99.9)**: 
- **Memory Usage**: 
- **CPU Usage**: 
- **Load**: <!-- e.g., 1M RPS -->

## Expected Performance

<!-- What performance do you expect? -->

- **Throughput**: 
- **Latency (p50/p99/p99.9)**: 
- **Memory Usage**: 
- **CPU Usage**: 

## Environment

- **Blitz Version**: 
- **OS**: 
- **CPU**: <!-- e.g., AMD EPYC 9754, 128 cores -->
- **RAM**: 
- **Network**: <!-- e.g., 10Gbps, 25Gbps, 100Gbps -->

## Profiling Data

<!-- Attach profiling results (flamegraphs, perf reports, etc.) -->

```
# perf report or similar

```

## Benchmark Results

<!-- Provide benchmark data -->

```bash
# Benchmark commands and results

```

## Configuration

<!-- Relevant configuration settings -->

```toml
# config.toml

```

## Hot Paths Identified

<!-- If you've identified specific bottlenecks -->

1. 
2. 

## Proposed Optimizations

<!-- Optional: Suggested improvements -->



## Additional Context

<!-- Any other relevant information -->



