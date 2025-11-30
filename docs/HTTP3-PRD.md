# Product Requirements Document: HTTP/3/QUIC Support for Blitz Gateway



## Executive Summary



**Project:** HTTP/3/QUIC Protocol Implementation  

**Version:** 0.3 Milestone  

**Target Release:** Q1 2026  

**Goal:** Implement production-ready HTTP/3 with pure Zig QUIC stack to achieve <120µs p99 latency and position Blitz as the superior alternative to Kong and APISIX



---



## 1. Strategic Context



### 1.1 Vision

Complete Blitz's protocol trifecta (HTTP/1.1 ✅, HTTP/2 ✅, HTTP/3 🚧) to become the fastest, most complete edge gateway capable of replacing Kong and APISIX in production environments.



### 1.2 Market Position

- **Current State:** Kong and APISIX lack sub-100µs latency and modern protocol optimization

- **Blitz Advantage:** Pure Zig implementation targeting 10M+ RPS with <120µs p99 for HTTP/3

- **Competitive Edge:** First edge gateway to achieve enterprise-grade HTTP/3 performance on commodity hardware



### 1.3 Success Metrics

| Metric | Target | Kong/APISIX Baseline |

|--------|--------|---------------------|

| HTTP/3 p99 Latency | ≤ 120 µs | ~2-5 ms |

| QUIC Handshake Time | ≤ 50 ms | ~100-150 ms |

| RPS at 35% CPU (128-core) | ≥ 8M RPS | ~100K-500K RPS |

| Memory at 5M RPS | ≤ 250 MB | ~1-2 GB |

| 0-RTT Success Rate | ≥ 95% | N/A (limited support) |



---



## 2. Technical Requirements



### 2.1 Core QUIC Implementation



#### 2.1.1 Transport Layer

**Must Have (v0.3):**

- Pure Zig QUIC transport (RFC 9000) with zero external dependencies

- Connection establishment with 1-RTT and 0-RTT resumption

- Loss detection and congestion control (Cubic, BBR)

- Path MTU discovery and packet pacing

- Connection migration support

- Multiplexed streams with flow control per stream and connection



**Should Have (v0.4):**

- QUIC v2 (RFC 9369) support

- ECN (Explicit Congestion Notification) support

- Multipath QUIC (draft-ietf-quic-multipath)



#### 2.1.2 Cryptography

**Must Have:**

- TLS 1.3 integration with QUIC crypto frames

- Key derivation for QUIC packet protection

- Header protection (RFC 9001)

- 0-RTT data encryption with anti-replay

- ChaCha20-Poly1305 and AES-128-GCM cipher suites



**Performance Target:**

- Handshake completion: <50ms (1-RTT), <10ms (0-RTT)

- Encryption overhead: <5µs per packet



#### 2.1.3 Packet Processing

**Must Have:**

- Zero-copy packet parsing with SIMD acceleration

- Coalesced packet handling

- Retry and version negotiation

- Stateless reset support

- Amplification attack mitigation



**Architecture:**

```
UDP Socket (io_uring)

    ↓

QUIC Packet Parser (SIMD)

    ↓

Connection Demultiplexer

    ↓

Stream Demultiplexer

    ↓

HTTP/3 Frame Handler

    ↓

Routing Engine
```



### 2.2 HTTP/3 Implementation



#### 2.2.1 Framing (RFC 9114)

**Must Have:**

- DATA frame: Efficient payload delivery

- HEADERS frame: Request/response headers with QPACK

- SETTINGS frame: Configuration negotiation

- GOAWAY frame: Graceful shutdown

- CANCEL_PUSH frame: Server push cancellation (if implemented)



**Should Have:**

- Server push support (configurable, disabled by default)

- Extended CONNECT for WebSocket-over-HTTP/3



#### 2.2.2 QPACK (RFC 9204)

**Must Have:**

- Dynamic table with encoder/decoder streams

- Static table (RFC 9114 Appendix A)

- Field line representation (indexed, literal with/without name reference)

- Dynamic table size updates

- Stream cancellation handling



**Performance Target:**

- Header compression ratio: ≥85%

- Encoding/decoding latency: <10µs per header block



#### 2.2.3 Stream Priorities (RFC 9218)

**Should Have:**

- Extensible priority scheme

- Urgency and incremental parameters

- Priority frame support



### 2.3 Integration Architecture



#### 2.3.1 Server Integration

**Must Have:**

- Unified server accepting HTTP/1.1, HTTP/2, HTTP/3 on different ports

- ALPN negotiation: h3, h3-29 (draft versions for compatibility)

- Alt-Svc header advertising HTTP/3 availability

- Seamless protocol upgrade path for clients



**Port Configuration:**

- HTTP/1.1 & HTTP/2: Port 8080 (existing)

- HTTP/3 (QUIC): Port 443/UDP (default) or configurable



#### 2.3.2 Load Balancer Integration

**Must Have:**

- HTTP/3 backend connection pooling

- Health checks over QUIC

- Connection ID routing for connection migration

- Retry and failover logic



**Nice to Have:**

- Sticky sessions using QUIC connection ID

- Active/active backend selection



#### 2.3.3 Monitoring & Observability

**Must Have:**

- QUIC-specific metrics:

  - Handshake success/failure rate

  - 0-RTT acceptance rate

  - Packet loss rate

  - RTT measurements

  - Stream multiplexing utilization

- HTTP/3 request metrics (latency, status codes, throughput)

- Connection migration events



**Integration:**

- Prometheus exporter with QUIC metrics

- OpenTelemetry tracing for request flows



---



## 3. Performance Targets



### 3.1 Benchmark Specifications



**Test Environment:**

- AMD EPYC 9754, 128-core bare metal

- Ubuntu 24.04 LTS Minimal

- 100 Gbps network

- io_uring with kernel 6.5+



**Benchmarks:**



| Scenario | Target RPS | Target p99 Latency | Memory Usage |

|----------|-----------|-------------------|--------------|

| HTTP/3 echo (small payload) | ≥ 8M | ≤ 120 µs | ≤ 250 MB |

| HTTP/3 + TLS 1.3 (keep-alive) | ≥ 6M | ≤ 150 µs | ≤ 300 MB |

| HTTP/3 with 0-RTT | ≥ 9M | ≤ 100 µs | ≤ 250 MB |

| Mixed HTTP/1.1 + HTTP/2 + HTTP/3 | ≥ 10M combined | ≤ 120 µs | ≤ 400 MB |



### 3.2 Comparison Targets



**Kong Gateway:**

- Current: ~100K-300K RPS, 2-5ms latency, 1-2GB memory

- Blitz Target: 30-80x RPS improvement, 20-40x latency reduction



**APISIX:**

- Current: ~200K-500K RPS, 1-3ms latency, 800MB-1.5GB memory

- Blitz Target: 16-40x RPS improvement, 10-25x latency reduction



---



## 4. Development Phases



### 4.1 Phase 1: QUIC Foundation (6 weeks)



**Deliverables:**

- Basic QUIC connection establishment (1-RTT)

- Packet framing and parsing

- Stream multiplexing

- Loss detection (basic)

- Unit tests for core QUIC functions



**Acceptance Criteria:**

- Successful handshake with test clients

- 1000+ concurrent connections stable

- Basic interoperability with curl --http3



### 4.2 Phase 2: HTTP/3 Framing (4 weeks)



**Deliverables:**

- HTTP/3 frame parser/generator

- QPACK static table compression

- Request/response handling

- Integration with existing routing engine

- Basic HTTP/3 echo server



**Acceptance Criteria:**

- Serve HTTP/3 requests end-to-end

- Pass HTTP/3 conformance tests

- Interoperability with Chrome, Firefox, curl



### 4.3 Phase 3: Advanced Features (4 weeks)



**Deliverables:**

- 0-RTT resumption

- Connection migration

- Congestion control (Cubic, BBR)

- QPACK dynamic table

- Performance optimizations (SIMD, zero-copy)



**Acceptance Criteria:**

- 0-RTT success rate >95%

- Connection migration success rate >90%

- 5M+ RPS in benchmarks



### 4.4 Phase 4: Load Balancer Integration (3 weeks)



**Deliverables:**

- HTTP/3 backend connection pool

- Health checks over QUIC

- Connection ID-based routing

- Metrics and monitoring



**Acceptance Criteria:**

- Load balancing across 10+ backends

- <5% failed health checks under load

- Full observability dashboard



### 4.5 Phase 5: Production Hardening (3 weeks)



**Deliverables:**

- Security hardening (amplification attacks, replay attacks)

- Configuration system for QUIC parameters

- Documentation and migration guide

- Benchmark suite comparing to Kong/APISIX

- Production-ready release



**Acceptance Criteria:**

- Pass security audit

- 10M+ RPS in production benchmarks

- <120µs p99 latency achieved

- Zero critical bugs in 1-week soak test



**Total Timeline:** 20 weeks (~5 months)



---



## 5. Configuration API



### 5.1 QUIC Configuration



```zig

const QUICConfig = struct {

    enabled: bool = true,

    port: u16 = 443,

    max_idle_timeout_ms: u64 = 30000,

    max_udp_payload_size: u16 = 1350,

    initial_max_data: u64 = 10_000_000,

    initial_max_stream_data_bidi_local: u64 = 1_000_000,

    initial_max_stream_data_bidi_remote: u64 = 1_000_000,

    initial_max_stream_data_uni: u64 = 1_000_000,

    initial_max_streams_bidi: u64 = 100,

    initial_max_streams_uni: u64 = 100,

    enable_0rtt: bool = true,

    enable_early_data: bool = true,

    congestion_control: enum { cubic, bbr, reno } = .cubic,

};

```



### 5.2 HTTP/3 Configuration



```zig

const HTTP3Config = struct {

    max_field_section_size: u64 = 16384,

    qpack_max_table_capacity: u64 = 4096,

    qpack_blocked_streams: u64 = 100,

    enable_server_push: bool = false,

    enable_extended_connect: bool = false,

    enable_datagrams: bool = false,

};

```



---



## 6. Testing Strategy



### 6.1 Unit Tests

- QUIC packet parsing/generation

- Frame encoding/decoding

- QPACK compression/decompression

- Stream state machine

- Loss detection algorithms



**Target Coverage:** ≥90%



### 6.2 Integration Tests

- End-to-end HTTP/3 request/response

- Connection migration

- 0-RTT resumption

- Multi-stream scenarios

- Load balancer integration



**Target Scenarios:** 50+ test cases



### 6.3 Interoperability Tests

- Test against multiple client implementations:

  - curl with HTTP/3

  - Chrome/Firefox

  - quiche (Cloudflare)

  - NGINX QUIC

- Participate in QUIC Interop Runner



### 6.4 Performance Tests

- Throughput benchmarks (wrk2 with HTTP/3 support)

- Latency profiling under load

- Memory leak detection (valgrind, AddressSanitizer)

- Stress tests (24-hour soak, connection churn)



### 6.5 Security Tests

- Amplification attack mitigation

- Replay attack prevention

- Fuzzing (AFL++, libFuzzer)

- Stateless reset validation



---



## 7. Documentation Requirements



### 7.1 User Documentation

- HTTP/3 quickstart guide

- Configuration reference

- Performance tuning guide

- Migration from HTTP/2 to HTTP/3

- Troubleshooting guide



### 7.2 Developer Documentation

- QUIC implementation architecture

- HTTP/3 framing details

- Contributing guide for QUIC features

- API reference for QUIC/HTTP3 modules



### 7.3 Competitive Analysis

- Benchmark comparison: Blitz vs. Kong vs. APISIX

- Feature matrix

- Migration guide from Kong/APISIX to Blitz



---



## 8. Success Criteria



### 8.1 Functional Requirements

- [ ] HTTP/3 requests served end-to-end

- [ ] 1-RTT and 0-RTT connection establishment

- [ ] QPACK header compression working

- [ ] Connection migration support

- [ ] Load balancer integration complete

- [ ] Interoperability with major clients (Chrome, Firefox, curl)



### 8.2 Performance Requirements

- [ ] ≥8M RPS for HTTP/3 (bare metal)

- [ ] ≤120µs p99 latency

- [ ] ≤250MB memory at 5M RPS

- [ ] ≥95% 0-RTT acceptance rate

- [ ] <50ms handshake time (1-RTT)



### 8.3 Quality Requirements

- [ ] ≥90% unit test coverage

- [ ] Pass QUIC interop tests

- [ ] Zero critical security vulnerabilities

- [ ] 1-week soak test with zero crashes

- [ ] Complete documentation published



### 8.4 Business Requirements

- [ ] Demonstrable 20x+ performance advantage over Kong/APISIX

- [ ] Production-ready for v1.0 GA (Q2 2026)

- [ ] Public benchmarks published

- [ ] Migration guide for Kong/APISIX users



---



## 9. Risks & Mitigations



| Risk | Impact | Probability | Mitigation |

|------|--------|-------------|------------|

| QUIC complexity delays timeline | High | Medium | Incremental development, MVP first |

| Performance targets not met | High | Low | Early profiling, SIMD optimization |

| Interoperability issues | Medium | Medium | Continuous testing with QUIC Interop Runner |

| Security vulnerabilities | High | Medium | Security audit, fuzzing, peer review |

| Resource constraints (team size) | Medium | Low | Focus on core features, defer nice-to-haves |



---



## 10. Dependencies



### 10.1 Internal Dependencies

- Existing TLS 1.3 implementation ✅

- io_uring event loop ✅

- Routing engine integration 🚧

- Load balancer module ✅



### 10.2 External Dependencies

- Zig 0.12.0+ compiler

- Linux kernel 5.15+ (io_uring)

- UDP socket performance tuning



### 10.3 Knowledge Dependencies

- QUIC RFC 9000 expertise

- HTTP/3 RFC 9114 expertise

- Cryptography (RFC 9001)

- High-performance networking



---



## 11. Go-to-Market Strategy



### 11.1 Launch Plan

1. **Private Beta (Q1 2026):** 10-20 early adopters, feedback iteration

2. **Public Beta (Q2 2026):** Open source release, community testing

3. **GA Release (Q2 2026):** Production-ready v1.0 with HTTP/3



### 11.2 Marketing Message

**"Blitz Gateway: The World's Fastest HTTP/3 Edge Proxy"**

- 20-80x faster than Kong and APISIX

- <120µs p99 latency on commodity hardware

- Pure Zig, zero dependencies, production-ready



### 11.3 Target Audience

- Companies migrating away from Kong/APISIX

- High-frequency trading firms

- Real-time gaming platforms

- Video streaming CDNs

- Fintech APIs requiring ultra-low latency



---



## 12. Next Steps



### Immediate Actions (Week 1-2)

1. Set up QUIC development branch

2. Design QUIC packet structure and state machine

3. Implement basic UDP socket with io_uring

4. Begin QUIC handshake implementation

5. Create HTTP/3 project board with tasks



### Short-term Milestones (Month 1)

- Working QUIC connection establishment

- Basic packet loss detection

- Initial interoperability test with curl



### Medium-term Milestones (Month 2-3)

- HTTP/3 framing complete

- 0-RTT resumption working

- 5M+ RPS achieved in benchmarks



---



## Appendix A: References



- RFC 9000: QUIC Transport Protocol

- RFC 9001: Using TLS to Secure QUIC

- RFC 9114: HTTP/3

- RFC 9204: QPACK: Field Compression for HTTP/3

- RFC 9218: Extensible Prioritization Scheme for HTTP

- [QUIC Interop Runner](https://interop.seemann.io/)



---



## Appendix B: Glossary



- **0-RTT:** Zero Round-Trip Time resumption, allows sending data in the first packet

- **ALPN:** Application-Layer Protocol Negotiation

- **BBR:** Bottleneck Bandwidth and RTT congestion control

- **CUBIC:** TCP-friendly congestion control algorithm

- **QPACK:** QPACK is HTTP/3's header compression format

- **RPS:** Requests Per Second



---



**Document Owner:** Blitz Gateway Core Team  

**Last Updated:** November 30, 2025  

**Status:** Draft for Review  

**Version:** 1.0

