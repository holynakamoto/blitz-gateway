#!/usr/bin/env python3
"""
QUIC/HTTP3 Client Test Tool
Validates QUIC handshake and HTTP3 session establishment
Requires: aioquic library (pip install aioquic)
"""
import asyncio
import argparse
import sys
import time
from dataclasses import dataclass
from typing import Optional, List
import logging

try:
    from aioquic.asyncio import connect
    from aioquic.asyncio.protocol import QuicConnectionProtocol
    from aioquic.h3.connection import H3Connection
    from aioquic.h3.events import HeadersReceived, DataReceived
    from aioquic.quic.configuration import QuicConfiguration
    from aioquic.quic.events import QuicEvent
    AIOQUIC_AVAILABLE = True
except ImportError:
    AIOQUIC_AVAILABLE = False

@dataclass
class TestResult:
    """Result of a validation test"""
    test_name: str
    passed: bool
    message: str
    duration_ms: int
    details: Optional[str] = None

class HTTP3Client(QuicConnectionProtocol):
    """HTTP/3 client protocol handler"""
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._h3 = H3Connection(self._quic)
        self._requests = {}
        self._responses = {}
        self._handshake_complete = False
        
    def quic_event_received(self, event: QuicEvent):
        """Handle QUIC events"""
        # Check for handshake completion
        if hasattr(event, '__class__'):
            event_name = event.__class__.__name__
            if event_name == 'HandshakeCompleted':
                self._handshake_complete = True
                logging.info("✓ QUIC handshake completed")
        
        # Process HTTP/3 events
        for h3_event in self._h3.handle_event(event):
            if isinstance(h3_event, HeadersReceived):
                stream_id = h3_event.stream_id
                headers = h3_event.headers
                self._responses[stream_id] = {
                    'headers': headers,
                    'data': b''
                }
                logging.debug(f"Received headers on stream {stream_id}: {headers}")
                
            elif isinstance(h3_event, DataReceived):
                stream_id = h3_event.stream_id
                if stream_id in self._responses:
                    self._responses[stream_id]['data'] += h3_event.data
                logging.debug(f"Received {len(h3_event.data)} bytes on stream {stream_id}")
    
    async def send_request(self, url: str) -> dict:
        """Send an HTTP/3 request"""
        stream_id = self._quic.get_next_available_stream_id()
        
        headers = [
            (b":method", b"GET"),
            (b":scheme", b"https"),
            (b":authority", url.encode()),
            (b":path", b"/"),
        ]
        
        self._h3.send_headers(stream_id, headers)
        self._requests[stream_id] = url
        
        # Wait for response with timeout
        timeout = 5.0
        start = time.time()
        while stream_id not in self._responses:
            if time.time() - start > timeout:
                raise TimeoutError("Request timeout")
            await asyncio.sleep(0.01)
        
        return self._responses[stream_id]
    
    def is_handshake_complete(self) -> bool:
        """Check if QUIC handshake is complete"""
        return self._handshake_complete

class QuicValidator:
    """QUIC/HTTP3 session validator"""
    
    def __init__(self, host: str, port: int, timeout: int = 5):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.results: List[TestResult] = []
    
    async def test_quic_handshake(self) -> TestResult:
        """Test QUIC handshake completion"""
        start_time = time.time()
        
        try:
            # Configure QUIC connection
            configuration = QuicConfiguration(
                is_client=True,
                alpn_protocols=["h3"],  # HTTP/3
                verify_mode=None,  # Skip certificate verification for testing
            )
            
            logging.info(f"→ Connecting to {self.host}:{self.port}")
            
            async with connect(
                self.host,
                self.port,
                configuration=configuration,
                create_protocol=HTTP3Client,
            ) as client:
                # Wait for handshake
                timeout = self.timeout
                start = time.time()
                while not client.is_handshake_complete():
                    if time.time() - start > timeout:
                        raise TimeoutError("Handshake timeout")
                    await asyncio.sleep(0.01)
                
                duration_ms = int((time.time() - start_time) * 1000)
                
                return TestResult(
                    test_name="QUIC Handshake",
                    passed=True,
                    message="Handshake completed successfully",
                    duration_ms=duration_ms,
                    details=f"Protocol: {client._quic.configuration.alpn_protocols}"
                )
                
        except TimeoutError:
            duration_ms = int((time.time() - start_time) * 1000)
            return TestResult(
                test_name="QUIC Handshake",
                passed=False,
                message="Handshake timeout",
                duration_ms=duration_ms,
                details="Server did not complete handshake within timeout period"
            )
        except Exception as e:
            duration_ms = int((time.time() - start_time) * 1000)
            return TestResult(
                test_name="QUIC Handshake",
                passed=False,
                message=f"Handshake failed: {type(e).__name__}",
                duration_ms=duration_ms,
                details=str(e)
            )
    
    async def test_http3_request(self) -> TestResult:
        """Test HTTP/3 request/response"""
        start_time = time.time()
        
        try:
            configuration = QuicConfiguration(
                is_client=True,
                alpn_protocols=["h3"],
                verify_mode=None,
            )
            
            logging.info(f"→ Sending HTTP/3 GET request to {self.host}:{self.port}")
            
            async with connect(
                self.host,
                self.port,
                configuration=configuration,
                create_protocol=HTTP3Client,
            ) as client:
                # Send HTTP/3 request
                response = await client.send_request(f"{self.host}:{self.port}")
                
                duration_ms = int((time.time() - start_time) * 1000)
                
                status = None
                for name, value in response['headers']:
                    if name == b':status':
                        status = value.decode()
                        break
                
                return TestResult(
                    test_name="HTTP/3 Request",
                    passed=status is not None,
                    message=f"Received HTTP response (status: {status})" if status else "No status in response",
                    duration_ms=duration_ms,
                    details=f"Response size: {len(response['data'])} bytes"
                )
                
        except Exception as e:
            duration_ms = int((time.time() - start_time) * 1000)
            return TestResult(
                test_name="HTTP/3 Request",
                passed=False,
                message=f"Request failed: {type(e).__name__}",
                duration_ms=duration_ms,
                details=str(e)
            )
    
    async def run_all_tests(self) -> List[TestResult]:
        """Run all validation tests"""
        print("\n╔═══════════════════════════════════════════════════════════╗")
        print("║  QUIC/HTTP3 Session Validation Suite (Python)            ║")
        print("╠═══════════════════════════════════════════════════════════╣")
        print(f"║  Server: {self.host}:{self.port:<44} ║")
        print("╚═══════════════════════════════════════════════════════════╝\n")
        
        tests = [
            ("Test 1: QUIC Handshake", self.test_quic_handshake),
            ("Test 2: HTTP/3 Request", self.test_http3_request),
        ]
        
        for test_name, test_func in tests:
            print(f"{test_name}")
            result = await test_func()
            self.results.append(result)
            self._print_result(result)
            print()
            
            # Small delay between tests
            await asyncio.sleep(0.5)
        
        return self.results
    
    def _print_result(self, result: TestResult):
        """Print test result"""
        status = "✓ PASS" if result.passed else "✗ FAIL"
        color = "\x1b[32m" if result.passed else "\x1b[31m"
        reset = "\x1b[0m"
        
        print(f"  {color}{status}{reset} - {result.message} ({result.duration_ms} ms)")
        if result.details:
            print(f"        {result.details}")
    
    def print_summary(self):
        """Print test summary"""
        passed = sum(1 for r in self.results if r.passed)
        failed = sum(1 for r in self.results if not r.passed)
        
        print("\n╔═══════════════════════════════════════════════════════════╗")
        print("║  Test Summary                                             ║")
        print("╠═══════════════════════════════════════════════════════════╣")
        print(f"║  Total Tests: {len(self.results):<3}                                         ║")
        print(f"║  \x1b[32mPassed: {passed:<3}\x1b[0m                                             ║")
        print(f"║  \x1b[31mFailed: {failed:<3}\x1b[0m                                             ║")
        print("╚═══════════════════════════════════════════════════════════╝\n")
        
        if failed > 0:
            print("⚠️  Some tests failed. Recommendations:")
            print("   - Verify server is running and listening on specified port")
            print("   - Check server logs for handshake errors")
            print("   - Ensure certificates are properly configured")
            print("   - Verify QUIC version compatibility (RFC 9000)\n")
        else:
            print("🎉 All tests passed! QUIC/HTTP3 is fully operational.\n")
        
        return failed == 0

async def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description="QUIC/HTTP3 Session Validator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                          # Test localhost:8443
  %(prog)s 192.168.1.100 4433       # Test specific server
  %(prog)s -v                       # Verbose logging
        """
    )
    parser.add_argument("host", nargs="?", default="127.0.0.1", help="Server hostname/IP (default: 127.0.0.1)")
    parser.add_argument("port", nargs="?", type=int, default=8443, help="Server port (default: 8443)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Enable verbose logging")
    parser.add_argument("-t", "--timeout", type=int, default=5, help="Timeout in seconds (default: 5)")
    
    args = parser.parse_args()
    
    # Setup logging
    log_level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=log_level,
        format='%(levelname)s: %(message)s'
    )
    
    if not AIOQUIC_AVAILABLE:
        print("❌ Error: aioquic library not found")
        print("\nInstall it with:")
        print("  pip install aioquic")
        print("\nOr use the Zig validator instead:")
        print("  zig run quic_validator.zig")
        sys.exit(1)
    
    validator = QuicValidator(args.host, args.port, args.timeout)
    await validator.run_all_tests()
    success = validator.print_summary()
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
        sys.exit(1)

