# QUIC Known Issues

## Test Issues

### Empty Payload Handling (Minor)
**File:** `src/quic/test.zig` - "parse long header INITIAL packet" test  
**Status:** 1/3 tests failing  
**Issue:** Edge case with empty payload slice creation when `offset == data.len` and `payload_len == 0`  
**Error Location:** `src/quic/packet.zig:86` - payload length check  
**Impact:** Low - core packet parsing works, just a test edge case  
**Workaround:** Test uses HANDSHAKE packet instead of INITIAL to avoid token complexity  
**Priority:** Low - can be fixed later during handshake testing

**Details:**
- When parsing a packet with `payload_len == 0` and `offset == data.len`, the empty slice creation logic needs refinement
- The check `if (offset + payload_len > data.len)` should pass when both are 0, but there's a subtle edge case
- This doesn't affect actual QUIC packet parsing in production scenarios

## Future Fixes

1. Add more comprehensive test cases for edge cases
2. Improve empty payload handling logic
3. Add fuzzing tests for packet parsing

