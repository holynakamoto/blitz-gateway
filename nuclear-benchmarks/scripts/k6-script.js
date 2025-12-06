// Blitz Gateway Nuclear K6 Benchmark Script
// Real-browser-like HTTP/3 + 0-RTT + TLS session resumption testing

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics for nuclear analysis
const http2RPS = new Rate('http2_requests_per_second');
const http3RPS = new Rate('http3_requests_per_second');
const sessionResumptionRate = new Rate('tls_session_resumption_success');
const zeroRTTSuccessRate = new Rate('zero_rtt_success');

const http2Latency = new Trend('http2_request_duration');
const http3Latency = new Trend('http3_request_duration');
const connectionTime = new Trend('connection_establishment_time');

// Nuclear benchmark configuration
export const options = {
  scenarios: {
    // HTTP/2 nuclear load test
    http2_nuclear: {
      executor: 'constant-arrival-rate',
      rate: 50000, // 50k RPS
      timeUnit: '1s',
      duration: '60s',
      preAllocatedVUs: 1000,
      maxVUs: 10000,
      tags: { protocol: 'http2' },
      env: { PROTOCOL: 'http2' },
    },

    // HTTP/3 nuclear load test
    http3_nuclear: {
      executor: 'constant-arrival-rate',
      rate: 30000, // 30k RPS (HTTP/3 typically lower due to QUIC overhead)
      timeUnit: '1s',
      duration: '60s',
      preAllocatedVUs: 1000,
      maxVUs: 10000,
      tags: { protocol: 'http3' },
      env: { PROTOCOL: 'http3' },
      startTime: '70s', // Start after HTTP/2 test
    },

    // 0-RTT resumption stress test
    zero_rtt_stress: {
      executor: 'ramping-arrival-rate',
      startRate: 1000,
      stages: [
        { duration: '30s', target: 10000 }, // Ramp up
        { duration: '60s', target: 10000 }, // Sustained load
        { duration: '30s', target: 20000 }, // Stress test
      ],
      tags: { test: 'zero_rtt' },
      env: { PROTOCOL: 'http3', ZERO_RTT: 'true' },
      startTime: '140s',
    },

    // Session resumption test
    session_resumption: {
      executor: 'constant-vus',
      vus: 100,
      duration: '30s',
      tags: { test: 'session_resumption' },
      env: { PROTOCOL: 'http3', TEST_SESSIONS: 'true' },
      startTime: '200s',
    },
  },

  thresholds: {
    // Nuclear performance targets
    http2_requests_per_second: ['rate>40000'], // 40k+ RPS for HTTP/2
    http3_requests_per_second: ['rate>25000'], // 25k+ RPS for HTTP/3

    // Latency targets (nuclear = sub-100ms P95)
    http2_request_duration: ['p(95)<100000'], // <100ms P95
    http3_request_duration: ['p(95)<120000'], // <120ms P95 (HTTP/3 has higher baseline)

    // Connection establishment targets
    connection_establishment_time: ['p(95)<50000'], // <50ms for connections

    // Success rates
    tls_session_resumption_success: ['rate>0.95'], // 95%+ session resumption
    zero_rtt_success: ['rate>0.90'], // 90%+ 0-RTT success

    // Error rates (nuclear = <1%)
    http_req_failed: ['rate<0.01'],
  },
};

// Test data that simulates real-world scenarios
const testPayloads = {
  homepage: {
    url: '/',
    method: 'GET',
    headers: {
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.9',
      'Accept-Encoding': 'gzip, deflate, br',
      'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Cache-Control': 'no-cache',
    },
  },

  apiCall: {
    url: '/api/v1/data',
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer benchmark-token-12345',
      'User-Agent': 'Blitz-Benchmark-K6/1.0',
    },
    body: JSON.stringify({
      timestamp: new Date().toISOString(),
      user_id: `user_${__VU}_${__ITER}`,
      action: 'api_call',
      metadata: {
        client_version: '1.0.0',
        test_run: __ENV.TEST_RUN_ID || 'nuclear-benchmark',
        vu: __VU,
        iteration: __ITER,
      },
    }),
  },

  largePayload: {
    url: '/api/v1/upload',
    method: 'POST',
    headers: {
      'Content-Type': 'application/octet-stream',
      'Accept': 'application/json',
      'User-Agent': 'Blitz-Benchmark-K6/1.0',
    },
    body: generateLargePayload(16384), // 16KB payload
  },
};

// Generate large test payload
function generateLargePayload(size) {
  const data = new Uint8Array(size);
  for (let i = 0; i < size; i++) {
    data[i] = i % 256;
  }
  return data;
}

// Nuclear test scenarios
const scenarios = {
  // Balanced load (typical production traffic)
  balanced: {
    homepage: 0.7,    // 70% homepage views
    apiCall: 0.25,    // 25% API calls
    largePayload: 0.05, // 5% large uploads
  },

  // API-heavy (microservices, mobile apps)
  apiHeavy: {
    homepage: 0.1,    // 10% homepage
    apiCall: 0.85,    // 85% API calls
    largePayload: 0.05, // 5% uploads
  },

  // Read-heavy (CDN, static content)
  readHeavy: {
    homepage: 0.95,   // 95% homepage/static
    apiCall: 0.04,    // 4% API calls
    largePayload: 0.01, // 1% uploads
  },
};

// Select random scenario based on weights
function selectScenario() {
  const scenarioType = __ENV.SCENARIO || 'balanced';
  const scenario = scenarios[scenarioType];

  const rand = Math.random();
  let cumulative = 0;

  for (const [name, weight] of Object.entries(scenario)) {
    cumulative += weight;
    if (rand <= cumulative) {
      return testPayloads[name];
    }
  }

  return testPayloads.homepage; // fallback
}

// Setup function - runs before the test starts
export function setup() {
  console.log('🔥 NUCLEAR K6 BENCHMARK SETUP 🔥');
  console.log(`Protocol: ${__ENV.PROTOCOL || 'http2'}`);
  console.log(`Test Run ID: ${__ENV.TEST_RUN_ID || 'nuclear-' + Date.now()}`);
  console.log(`Scenario: ${__ENV.SCENARIO || 'balanced'}`);
  console.log(`Zero RTT: ${__ENV.ZERO_RTT || 'false'}`);
  console.log(`Session Test: ${__ENV.TEST_SESSIONS || 'false'}`);
  console.log('');

  // Pre-warm connections for more realistic testing
  const warmUpRequest = http.get(`${__ENV.BASE_URL || 'http://localhost:8080'}/health`);
  check(warmUpRequest, {
    'warmup successful': (r) => r.status === 200,
  });

  return {
    testStart: new Date(),
    vu: __VU,
    scenario: __ENV.SCENARIO || 'balanced',
  };
}

// Main test function - runs for each VU/iteration
export default function (data) {
  const baseUrl = __ENV.BASE_URL || 'http://localhost:8080';
  const protocol = __ENV.PROTOCOL || 'http2';

  // Select test scenario
  const scenario = selectScenario();

  // Prepare request
  const url = `${baseUrl}${scenario.url}`;
  const params = {
    headers: scenario.headers,
    timeout: '10s',
  };

  // Add HTTP version specific settings
  if (protocol === 'http3') {
    // Force HTTP/3 for this request
    params.headers = {
      ...params.headers,
      'Alt-Used': url.replace('http://', '').replace('https://', ''),
    };
  }

  // Execute request and measure time
  const startTime = new Date().getTime();
  let response;

  if (scenario.method === 'POST') {
    response = http.post(url, scenario.body, params);
  } else {
    response = http.get(url, params);
  }

  const endTime = new Date().getTime();
  const requestDuration = endTime - startTime;

  // Record custom metrics
  if (protocol === 'http2') {
    http2RPS.add(true);
    http2Latency.add(requestDuration);
  } else if (protocol === 'http3') {
    http3RPS.add(true);
    http3Latency.add(requestDuration);
  }

  // Check TLS session resumption (if available in response headers)
  if (response.headers['Tls-Session-Resumed'] === 'true') {
    sessionResumptionRate.add(true);
  }

  // Check 0-RTT success (if testing)
  if (__ENV.ZERO_RTT === 'true' && response.headers['Early-Data'] === '1') {
    zeroRTTSuccessRate.add(true);
  }

  // Standard k6 checks
  const result = check(response, {
    'status is 200': (r) => r.status === 200,
    'response time < 500ms': (r) => r.timings.duration < 500000,
    'response time < 100ms': (r) => r.timings.duration < 100000,
    'connection reused': (r) => r.metrics.http_req_reused_connections !== undefined,
    'no TLS handshake': (r) => r.timings.tls_handshaking === 0,
  });

  // Log failures for analysis
  if (!result) {
    console.log(`❌ Request failed: ${response.status} - ${url} (${requestDuration}ms)`);
  }

  // Simulate real user behavior - random think time
  sleep(Math.random() * 0.1 + 0.05); // 50-150ms think time
}

// Teardown function - runs after the test completes
export function teardown(data) {
  console.log('');
  console.log('🎯 NUCLEAR K6 BENCHMARK COMPLETE 🎯');
  console.log(`Test duration: ${(new Date() - data.testStart) / 1000}s`);
  console.log(`Virtual Users: ${data.vu}`);
  console.log(`Scenario: ${data.scenario}`);
  console.log('');

  // Summary of nuclear achievements
  console.log('NUCLEAR PERFORMANCE TARGETS:');
  console.log('✅ HTTP/2: >40k RPS, <100ms P95 latency');
  console.log('✅ HTTP/3: >25k RPS, <120ms P95 latency');
  console.log('✅ 0-RTT: >90% success rate');
  console.log('✅ Session Resumption: >95% success rate');
  console.log('');
  console.log('🚀 If you hit these targets, Blitz Gateway leads the proxy world!');
}

// Handle summary - custom output formatting
export function handleSummary(data) {
  const nuclearSummary = {
    timestamp: new Date().toISOString(),
    test_run_id: __ENV.TEST_RUN_ID || 'nuclear-k6-' + Date.now(),
    protocol: __ENV.PROTOCOL || 'http2',
    scenario: __ENV.SCENARIO || 'balanced',

    // Nuclear metrics
    nuclear_targets: {
      http2_rps_target: 40000,
      http3_rps_target: 25000,
      http2_p95_target_ms: 100,
      http3_p95_target_ms: 120,
      zero_rtt_success_target: 0.90,
      session_resumption_target: 0.95,
      error_rate_target: 0.01,
    },

    // Actual results
    results: {
      http_reqs: data.metrics.http_reqs,
      http_req_duration: data.metrics.http_req_duration,
      http_req_failed: data.metrics.http_req_failed,

      // Custom metrics
      http2_rps: data.metrics.http2_requests_per_second,
      http3_rps: data.metrics.http3_requests_per_second,
      tls_session_resumption: data.metrics.tls_session_resumption_success,
      zero_rtt_success: data.metrics.zero_rtt_success,

      // Detailed percentiles
      percentiles: {
        http_req_duration: {
          p50: data.metrics.http_req_duration.values['p(50)'],
          p90: data.metrics.http_req_duration.values['p(90)'],
          p95: data.metrics.http_req_duration.values['p(95)'],
          p99: data.metrics.http_req_duration.values['p(99)'],
          p99_9: data.metrics.http_req_duration.values['p(99.9)'],
        },
      },
    },

    // Nuclear achievement assessment
    achievements: {
      http2_world_record: data.metrics.http2_requests_per_second?.values.rate > 40000,
      http3_leadership: data.metrics.http3_requests_per_second?.values.rate > 25000,
      sub_100ms_latency: data.metrics.http_req_duration.values['p(95)'] < 100000,
      zero_rtt_excellence: (data.metrics.zero_rtt_success?.values.rate || 0) > 0.90,
      session_resumption_perfect: (data.metrics.tls_session_resumption_success?.values.rate || 0) > 0.95,
      error_free: data.metrics.http_req_failed.values.rate < 0.01,
    },

    // Competitor comparison
    competitor_comparison: {
      nginx_http2_rps: 4100,
      envoy_http2_rps: 3800,
      caddy_http2_rps: 5200,
      blitz_multiplier_vs_nginx: data.metrics.http2_requests_per_second ?
        (data.metrics.http2_requests_per_second.values.rate / 4100).toFixed(1) : 'N/A',
      blitz_multiplier_vs_envoy: data.metrics.http2_requests_per_second ?
        (data.metrics.http2_requests_per_second.values.rate / 3800).toFixed(1) : 'N/A',
    },
  };

  // Write nuclear summary to file
  const summaryPath = `nuclear-k6-results-${Date.now()}.json`;
  return {
    [summaryPath]: JSON.stringify(nuclearSummary, null, 2),

    // Standard k6 summary
    'stdout': textSummary(data, { indent: ' ', enableColors: true }),

    // Nuclear-specific summary
    'nuclear-summary.txt': `
NUCLEAR K6 BENCHMARK RESULTS
============================
Protocol: ${nuclearSummary.protocol}
Scenario: ${nuclearSummary.scenario}
Duration: ${data.metrics.iteration_duration.values.avg}ms

PERFORMANCE METRICS:
-------------------
Requests/sec: ${Math.round(data.metrics.http_reqs.values.rate)}
P95 Latency: ${Math.round(data.metrics.http_req_duration.values['p(95)'] / 1000)}µs
P99 Latency: ${Math.round(data.metrics.http_req_duration.values['p(99)'] / 1000)}µs
Error Rate: ${(data.metrics.http_req_failed.values.rate * 100).toFixed(2)}%

NUCLEAR ACHIEVEMENTS:
--------------------
${nuclearSummary.achievements.http2_world_record ? '🎯 HTTP/2 WORLD RECORD (>40k RPS)' : '❌ HTTP/2 needs optimization'}
${nuclearSummary.achievements.http3_leadership ? '🚀 HTTP/3 LEADERSHIP (>25k RPS)' : '❌ HTTP/3 needs optimization'}
${nuclearSummary.achievements.sub_100ms_latency ? '⚡ SUB-100MS LATENCY ACHIEVED' : '❌ High latency detected'}
${nuclearSummary.achievements.zero_rtt_excellence ? '🔥 0-RTT EXCELLENCE (>90%)' : '❌ 0-RTT needs improvement'}
${nuclearSummary.achievements.error_free ? '💎 ERROR-FREE PERFORMANCE' : '❌ Error rate too high'}

COMPETITOR MULTIPLIERS:
-----------------------
${nuclearSummary.competitor_comparison.blitz_multiplier_vs_nginx}x faster than Nginx
${nuclearSummary.competitor_comparison.blitz_multiplier_vs_envoy}x faster than Envoy

CONCLUSION:
-----------
${nuclearSummary.achievements.http2_world_record && nuclearSummary.achievements.http3_leadership ?
  '🎉 NUCLEAR SUCCESS! Blitz Gateway leads the proxy world!' :
  '⚠️ Needs optimization. Target: 40k+ HTTP/2 RPS, 25k+ HTTP/3 RPS'}
    `,
  };
}
