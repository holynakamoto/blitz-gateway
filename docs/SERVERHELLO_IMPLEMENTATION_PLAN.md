# ServerHello Generation - Implementation Plan

## Current State Analysis

### ✅ What's Already Working

1. **CRYPTO Frame Parsing** (`src/quic/frames.zig`)
   - ✅ Complete CRYPTO frame parser
   - ✅ Can extract TLS handshake messages from frames
   - ✅ Handles variable-length integers correctly

2. **PicoTLS Integration** (`src/quic/picotls.zig`)
   - ✅ `TlsContext` structure exists
   - ✅ `feedClientHello()` method generates ServerHello
   - ✅ Handshake output is stored in `initial_output` buffer

3. **Handshake Manager** (`src/quic/handshake.zig`)
   - ✅ `processInitialPacket()` extracts CRYPTO frames
   - ✅ Feeds ClientHello to PicoTLS via `feedClientHello()`
   - ✅ `generateServerHello()` retrieves output from TLS context

4. **Packet Decryption** (`src/quic/udp_server.zig`)
   - ✅ Successfully decrypts Initial packets
   - ✅ Extracts CRYPTO frames from decrypted payload
   - ✅ Calls `processDecryptedPayload()` on connection

5. **Encryption Functions** (`src/quic/crypto.zig`)
   - ✅ `encryptPayload()` exists (line 202)
   - ✅ `removeHeaderProtection()` exists (line 275)
   - ✅ `applyHeaderProtection()` exists (line 313)

### ❌ What's Missing

1. **PicoTLS Context Initialization** ⚠️ **CRITICAL**
   - `quic_server.ssl_ctx` is set to `null` (line 120 in udp_server.zig)
   - Need to initialize `ptls_context_t` with certificates
   - Need to load cert.pem and key.pem files
   - **Without this, PicoTLS cannot generate ServerHello**

2. **Header Protection Application** ✅ **COMPLETE**
   - ✅ `removeHeaderProtection()` exists for decryption
   - ✅ `applyHeaderProtection()` exists for encryption (line 313)
   - Ready to use for outgoing packets

3. **CRYPTO Frame Reassembly**
   - CRYPTO frames can be fragmented across multiple packets
   - Need to properly reassemble using offset field
   - Current code may not handle fragmented ClientHello correctly

4. **Complete Packet Building**
   - `generateInitialPacket()` in `packet.zig` builds unprotected header
   - Need to encrypt payload and apply header protection
   - Need to integrate with `generateResponsePacket()` in `server.zig`

## Implementation Plan

### Phase 1: Initialize PicoTLS Context with Certificates ⚠️ **START HERE**

**File:** `src/quic/udp_server.zig`

**Goal:** Load certificates and initialize PicoTLS context before starting server

**Current Code:**
```zig
// Line 120 in udp_server.zig
quic_server.ssl_ctx = null;  // ❌ This prevents ServerHello generation
```

**Required Steps:**

1. **Add certificate loading function**
   ```zig
   // In udp_server.zig or new picotls_init.zig
   pub fn initPicoTlsContext(
       allocator: std.mem.Allocator,
       cert_path: []const u8,
       key_path: []const u8,
   ) !*c.ptls_context_t {
       // Load X509 certificate from PEM file
       // Load private key from PEM file
       // Initialize ptls_context_t with minicrypto backend
       // Set cipher suites: [&ptls_minicrypto_aes128gcmsha256, null]
       // Set key exchanges: [&ptls_minicrypto_x25519, null]
       // Return context
   }
   ```

2. **Initialize context in `runQuicServer()`**
   ```zig
   // Before creating QuicServer:
   const ptls_ctx = try initPicoTlsContext(allocator, cert_path, key_path);
   quic_server.ssl_ctx = @ptrCast(ptls_ctx);
   ```

3. **Pass context to handshake manager**
   ```zig
   // In processDecryptedPayload() or processInitialPacket():
   try conn.handshake_mgr.processInitialPacket(
       payload,
       quic_server.ssl_ctx,  // Now properly initialized
   );
   ```

**Dependencies:**
- Need to call `blitz_ptls_minicrypto_init()` from `picotls_wrapper.c`
- May need to add certificate loading helpers to `picotls_wrapper.c`
- PicoTLS minicrypto backend doesn't require OpenSSL

**Files to Modify:**
- `src/quic/udp_server.zig` - Add context initialization
- `src/quic/picotls_wrapper.c` - May need certificate loading functions

---

### Phase 2: Implement `applyHeaderProtection()`

**File:** `src/quic/crypto.zig`

**Goal:** Add function to apply header protection (inverse of `removeHeaderProtection()`)

**Current State:**
- `removeHeaderProtection()` exists (line 275)
- Need `applyHeaderProtection()` for outgoing packets

**Implementation:**
```zig
/// Apply header protection (RFC 9001 Section 5.4.2)
pub fn applyHeaderProtection(
    packet: []u8,
    hp_key: *const [HP_KEY_LEN]u8,
    pn_offset: usize,
) !void {
    // Sample starts 4 bytes after packet number
    const sample_offset = pn_offset + 4;
    if (sample_offset + 16 > packet.len) {
        return error.PacketTooShort;
    }

    const sample: *const [16]u8 = packet[sample_offset..][0..16];
    const mask = computeHpMask(hp_key, sample);

    // Apply mask to first byte (preserving fixed bits)
    const first_byte = packet[0];
    if ((first_byte & 0x80) != 0) {
        // Long header: mask bottom 4 bits
        packet[0] = first_byte ^ (mask[0] & 0x0F);
    } else {
        // Short header: mask bottom 5 bits
        packet[0] = first_byte ^ (mask[0] & 0x1F);
    }

    // Get packet number length from first byte
    const pn_len: u8 = (packet[0] & 0x03) + 1;

    // Apply mask to packet number bytes
    for (0..pn_len) |i| {
        packet[pn_offset + i] ^= mask[1 + i];
    }

    // Apply mask to length field (if present in long header)
    // Length field is at a fixed offset after SCID
    // Need to calculate this offset based on header structure
}
```

**Files to Modify:**
- `src/quic/crypto.zig` - Add `applyHeaderProtection()` function

---

### Phase 3: Build Complete Encrypted Initial Packet

**File:** `src/quic/server.zig` - `generateResponsePacket()`

**Goal:** Build complete encrypted Initial packet with ServerHello

**Current State:**
```zig
// Line 156-180 in server.zig
pub fn generateResponsePacket(...) !usize {
    const crypto_frame_len = try self.handshake_mgr.generateServerHello(&crypto_frame_buf);
    return try packet.generateInitialPacket(...);  // ❌ Not encrypted!
}
```

**Required Steps:**

1. **Get ServerHello from handshake manager**
   ```zig
   var crypto_frame_buf: [4096]u8 = undefined;
   const crypto_frame_len = try self.handshake_mgr.generateServerHello(&crypto_frame_buf);
   ```

2. **Build unprotected Initial packet header**
   ```zig
   // Use packet.generateInitialPacket() but don't include payload yet
   // We need to encrypt the payload first, then calculate length
   ```

3. **Encrypt CRYPTO frame payload**
   ```zig
   const secrets = self.handshake_mgr.initial_secrets.?;
   const pn = self.handshake_mgr.getNextInitialPN();
   
   var encrypted: [65536]u8 = undefined;
   const encrypted_len = try crypto.encryptPayload(
       crypto_frame_buf[0..crypto_frame_len],
       &secrets.server_key,  // SERVER key for server→client
       &secrets.server_iv,
       pn,
       header_aad,  // Unprotected header
       &encrypted,
   );
   ```

4. **Build complete packet with encrypted payload**
   ```zig
   // Build header with correct length (includes PN + encrypted payload)
   // Insert packet number
   // Insert encrypted payload
   ```

5. **Apply header protection**
   ```zig
   const pn_offset = /* calculate from header structure */;
   try crypto.applyHeaderProtection(
       packet_buf,
       &secrets.server_hp,
       pn_offset,
   );
   ```

**Files to Modify:**
- `src/quic/server.zig` - `generateResponsePacket()`
- May need helper in `src/quic/packet.zig` for encrypted packet building

---

### Phase 4: Fix CRYPTO Frame Reassembly

**File:** `src/quic/server.zig` - `processDecryptedPayload()`

**Current Issue:**
- CRYPTO frames are parsed but may not be properly reassembled
- The `offset` field in CRYPTO frames indicates where data belongs in the crypto stream
- Need to ensure complete ClientHello before feeding to PicoTLS

**Current Code:**
```zig
// Line 115-136 in server.zig
const crypto_frame = frames.CryptoFrame.parse(payload[offset..]);
// ❌ Not using offset field for reassembly
```

**Fix:**
The `handshake.QuicHandshake` already has `initial_crypto_stream` that should handle reassembly. Verify that `processInitialPacket()` in `handshake.zig` properly uses the offset field.

**Files to Review:**
- `src/quic/handshake.zig` - `processInitialPacket()` and `CryptoStream.append()`
- `src/quic/server.zig` - `processDecryptedPayload()`

---

## Implementation Order

### **Step 1: Initialize PicoTLS Context** ⚠️ **HIGHEST PRIORITY**

**Why First:** Without certificates, PicoTLS cannot generate ServerHello

**Estimated Time:** 2-3 hours

**Tasks:**
1. Create `initPicoTlsContext(cert_path, key_path)` function
2. Load X509 certificate from PEM file (or use PicoTLS's certificate loading)
3. Load private key from PEM file
4. Initialize `ptls_context_t` with minicrypto backend
5. Set cipher suites: `[&ptls_minicrypto_aes128gcmsha256, null]`
6. Set key exchanges: `[&ptls_minicrypto_x25519, null]`
7. Pass context to `QuicServer` on initialization

**Files to Modify:**
- `src/quic/udp_server.zig` - Add context initialization in `runQuicServer()`
- `src/quic/picotls_wrapper.c` - May need certificate loading helpers

**Key Function:**
```zig
pub fn initPicoTlsContext(
    allocator: std.mem.Allocator,
    cert_path: []const u8,
    key_path: []const u8,
) !*c.ptls_context_t {
    // Get context pointer
    const ctx = blitz_get_ptls_ctx();
    
    // Initialize with minicrypto
    blitz_ptls_minicrypto_init(&randomBytes);
    
    // Load certificate and key
    // (May need to add helpers to picotls_wrapper.c)
    
    return ctx;
}
```

---

### **Step 2: Verify Header Protection** ✅ **ALREADY EXISTS**

**Status:** `applyHeaderProtection()` already exists in `crypto.zig` (line 313)

**Quick Check:**
- Verify function signature matches usage needs
- May need to test with actual packet structure

---

### **Step 3: Build Encrypted Response Packet**

**Why Third:** Need to send encrypted ServerHello back to client

**Estimated Time:** 2-3 hours

**Tasks:**
1. Modify `generateResponsePacket()` to encrypt payload
2. Build complete packet with header + encrypted payload
3. Apply header protection
4. Return complete packet ready to send

**Files to Modify:**
- `src/quic/server.zig` - `generateResponsePacket()`
- May need helper in `src/quic/packet.zig`

---

### **Step 4: Verify CRYPTO Frame Reassembly**

**Why Fourth:** Ensure complete ClientHello is fed to PicoTLS

**Estimated Time:** 30 minutes

**Tasks:**
1. Review `CryptoStream.append()` implementation
2. Verify offset handling in `processInitialPacket()`
3. Test with fragmented ClientHello if possible

**Files to Review:**
- `src/quic/handshake.zig` - `CryptoStream` and `processInitialPacket()`

---

### **Step 5: End-to-End Testing**

**Why Last:** Verify complete handshake flow

**Estimated Time:** 1-2 hours

**Tasks:**
1. Start server with certificates
2. Send Initial packet from curl
3. Verify ServerHello is generated
4. Verify ServerHello is encrypted correctly
5. Verify packet is sent back to client
6. Check if client accepts ServerHello

---

## Key Functions Reference

### Existing Functions (✅ Ready to Use)

1. **`crypto.encryptPayload()`** - Encrypts payload with AES-128-GCM
2. **`crypto.removeHeaderProtection()`** - Removes header protection (for decryption)
3. **`frames.CryptoFrame.parse()`** - Parses CRYPTO frames
4. **`frames.CryptoFrame.generate()`** - Generates CRYPTO frames
5. **`packet.generateInitialPacket()`** - Builds Initial packet header (unprotected)
6. **`picotls.TlsContext.feedClientHello()`** - Generates ServerHello
7. **`handshake.QuicHandshake.generateServerHello()`** - Gets ServerHello from TLS context

### Functions to Implement (❌ Missing)

1. **`initPicoTlsContext()`** - Initialize PicoTLS with certificates
2. **`crypto.applyHeaderProtection()`** - Apply header protection to outgoing packets
3. **`buildEncryptedInitialPacket()`** - Complete encrypted packet builder

---

## Testing Strategy

### Unit Tests

1. **PicoTLS Context Initialization**
   - Test loading valid certificates
   - Test error handling for invalid certificates
   - Test minicrypto backend selection

2. **Header Protection**
   - Test `applyHeaderProtection()` with known packet
   - Verify round-trip: apply → remove → verify
   - Test with different packet number lengths

3. **Packet Encryption**
   - Test `encryptPayload()` with known plaintext
   - Verify decryption round-trip
   - Test with different payload sizes

### Integration Tests

1. **End-to-End Handshake**
   - Start server with certificates
   - Send Initial packet from test client
   - Verify ServerHello is received
   - Verify ServerHello can be decrypted

2. **Real Client Test**
   - Use `curl --http3-only` to connect
   - Verify handshake completes
   - Verify HTTP/3 request/response works

---

## Success Criteria

✅ **ServerHello Generation Complete When:**

1. ✅ Server loads certificates on startup
2. ✅ PicoTLS context is initialized with certificates
3. ✅ ClientHello is properly parsed from CRYPTO frames
4. ✅ ServerHello is generated by PicoTLS
5. ✅ ServerHello is encrypted with Initial keys
6. ✅ Encrypted packet is sent back to client
7. ✅ Client accepts ServerHello and continues handshake

---

## Next Immediate Steps

**Priority 1: Initialize PicoTLS Context**

1. Review PicoTLS documentation for certificate loading
2. Check if `picotls_wrapper.c` needs certificate loading functions
3. Implement `initPicoTlsContext()` function
4. Test context initialization with cert.pem/key.pem
5. Pass context to `QuicServer` and verify it's used

**Priority 2: Implement Header Protection**

1. Add `applyHeaderProtection()` to `crypto.zig`
2. Test with known packet structure
3. Verify round-trip with `removeHeaderProtection()`

**Priority 3: Complete Packet Building**

1. Modify `generateResponsePacket()` to encrypt payload
2. Apply header protection
3. Test with real client

---

## Estimated Timeline

- **Step 1 (Context Init):** 2-3 hours
- **Step 2 (Header Protection):** 1 hour
- **Step 3 (Packet Building):** 2-3 hours
- **Step 4 (Frame Reassembly):** 30 minutes
- **Step 5 (Testing):** 1-2 hours

**Total: 6.5-9.5 hours for complete ServerHello implementation**

---

## Notes

- PicoTLS minicrypto backend doesn't require OpenSSL
- Certificate loading may need to be done in C (picotls_wrapper.c)
- Header protection is symmetric (apply/remove use same algorithm)
- Packet number length affects header protection mask application
- Length field in Initial packets is also protected
