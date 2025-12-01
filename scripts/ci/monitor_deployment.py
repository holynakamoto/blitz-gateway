#!/usr/bin/env python3

"""
scripts/ci/monitor_deployment.py

Monitor deployment metrics and auto-rollback on issues
"""

import time
import sys
import argparse
import requests
from datetime import datetime, timedelta


class DeploymentMonitor:
    def __init__(self, prometheus_url: str, alert_threshold: dict):
        self.prometheus_url = prometheus_url
        self.alert_threshold = alert_threshold
        self.start_time = datetime.now()
    
    def query_prometheus(self, query: str) -> float:
        """Query Prometheus and return result"""
        try:
            response = requests.get(
                f"{self.prometheus_url}/api/v1/query",
                params={'query': query},
                timeout=5
            )
            data = response.json()
            
            if data['status'] == 'success' and data['data']['result']:
                return float(data['data']['result'][0]['value'][1])
        except Exception as e:
            print(f"Warning: Prometheus query failed: {e}")
        return 0.0
    
    def check_error_rate(self) -> bool:
        """Check if error rate is acceptable"""
        query = 'rate(http_requests_total{status=~"5.."}[5m])'
        error_rate = self.query_prometheus(query)
        
        threshold = self.alert_threshold.get('error_rate', 0.01)  # 1%
        
        if error_rate > threshold:
            print(f"❌ Error rate too high: {error_rate*100:.2f}% > {threshold*100:.2f}%")
            return False
        
        print(f"✅ Error rate OK: {error_rate*100:.2f}%")
        return True
    
    def check_latency(self) -> bool:
        """Check if p99 latency is acceptable"""
        query = 'histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))'
        p99_latency = self.query_prometheus(query) * 1_000_000  # Convert to µs
        
        threshold = self.alert_threshold.get('p99_latency_us', 200)  # 200µs
        
        if p99_latency > threshold:
            print(f"❌ P99 latency too high: {p99_latency:.0f}µs > {threshold}µs")
            return False
        
        print(f"✅ P99 latency OK: {p99_latency:.0f}µs")
        return True
    
    def check_memory(self) -> bool:
        """Check if memory usage is acceptable"""
        query = 'process_resident_memory_bytes'
        memory_bytes = self.query_prometheus(query)
        memory_mb = memory_bytes / (1024 * 1024)
        
        threshold = self.alert_threshold.get('memory_mb', 2048)  # 2GB
        
        if memory_mb > threshold:
            print(f"❌ Memory usage too high: {memory_mb:.0f}MB > {threshold}MB")
            return False
        
        print(f"✅ Memory usage OK: {memory_mb:.0f}MB")
        return True
    
    def monitor(self, duration_seconds: int) -> bool:
        """Monitor deployment for specified duration"""
        end_time = self.start_time + timedelta(seconds=duration_seconds)
        check_interval = 30  # seconds
        
        print(f"Monitoring deployment for {duration_seconds} seconds...")
        print(f"Start time: {self.start_time}")
        print(f"End time: {end_time}")
        print()
        
        while datetime.now() < end_time:
            elapsed = (datetime.now() - self.start_time).total_seconds()
            remaining = (end_time - datetime.now()).total_seconds()
            
            print(f"[{elapsed:.0f}s elapsed, {remaining:.0f}s remaining]")
            
            # Run all checks
            checks = [
                self.check_error_rate(),
                self.check_latency(),
                self.check_memory()
            ]
            
            # If any check fails, trigger rollback
            if not all(checks):
                print("\n❌ Health checks failed! Triggering rollback...")
                return False
            
            print()
            time.sleep(check_interval)
        
        print(f"✅ Deployment monitoring completed successfully")
        return True


def main():
    parser = argparse.ArgumentParser(description='Monitor deployment')
    parser.add_argument('--duration', type=int, default=300,
                       help='Monitoring duration in seconds')
    parser.add_argument('--prometheus-url', 
                       default='http://localhost:9090',
                       help='Prometheus URL')
    args = parser.parse_args()
    
    thresholds = {
        'error_rate': 0.01,      # 1%
        'p99_latency_us': 200,   # 200µs
        'memory_mb': 2048        # 2GB
    }
    
    monitor = DeploymentMonitor(args.prometheus_url, thresholds)
    
    success = monitor.monitor(args.duration)
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()

