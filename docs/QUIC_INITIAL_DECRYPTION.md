# QUIC Initial Packet Decryption - Key Learnings

## Overview

This document captures the critical learnings from implementing QUIC Initial packet decryption according to RFC 9001. The implementation required three specific fixes to correctly parse and decrypt QUIC Initial packets.

## Critical RFC 9001 Requirements

### 1. Header Protection Must Be Removed First

**The Problem:** The Length field and other header fields are protected by header protection. Attempting to parse them before removing header protection results in reading encrypted/garbage values (typically 0 or incorrect values).

**The Solution:** Remove header protection FIRST, then re-parse the packet structure with the unprotected headers.

**Implementation:**
```zig
// Step 1: Remove header protection
_ = crypto.removeHeaderProtection(packet_copy[0..data.len], &secrets.client_hp, pn_offset);

// Step 2: NOW re-parse the packet structure (headers are now unprotected)
var pos: usize = 0;
// ... parse version, DCID, SCID, token, length field, etc.
```

**Location in code:** `src/quic/udp_server.zig` - After header protection removal, before parsing length field.

---

### 2. Length Field Includes Packet Number

**The Problem:** The QUIC Length field specifies the combined length of the Packet Number AND Payload fields, not just the payload. Reading it as payload-only length causes off-by-one errors.

**RFC 9001 Section 17.2:**
> "Length: A variable-length integer specifying the length in bytes of the remainder of the packet (that is, the Packet Number and Payload fields)"

**The Solution:** Subtract the packet number length from the Length field value to get the actual encrypted payload length.

**Implementation:**
```zig
// Read Length field (includes PN + payload)
var payload_len: usize = /* varint decoding */;

// Get packet number length
const pn_len = 1 + @as(usize, header_type & 0x03);

// CRITICAL: Subtract packet number length
if (payload_len < pn_len) {
    return error.InvalidLength;
}
payload_len -= pn_len; // Now payload_len is the actual encrypted payload length
```

**Location in code:** `src/quic/udp_server.zig` - After reading Length field, before reading packet number.

---

### 3. AAD Includes Unprotected Packet Number

**The Problem:** The AEAD Additional Authenticated Data (AAD) must include the entire unprotected header, including the packet number. Excluding the packet number causes authentication failures.

**RFC 9001 Section 5.3:**
> "The associated data, A, for the AEAD is the contents of the QUIC header, starting from the flags byte of either the short or long header, up to and including the unprotected packet number."

**The Solution:** Construct AAD as `packet_copy[0..pos]` where `pos` is AFTER reading the packet number (pointing to the start of encrypted payload).

**Implementation:**
```zig
// Read packet number
const packet_number = /* read from packet_copy[pos] */;
pos += pn_len; // pos now points to start of encrypted payload

// AAD includes everything up to and including the packet number
const header_aad = packet_copy[0..pos]; // CORRECT - includes PN
// NOT: packet_copy[0..pn_offset] // WRONG - excludes PN
```

**Location in code:** `src/quic/udp_server.zig` - When constructing AAD for `decryptPayload()`.

---

## Correct Parsing Order

The correct order for parsing and decrypting a QUIC Initial packet is:

1. **Read unprotected fields** (first byte, version, DCID)
2. **Derive Initial secrets** from DCID
3. **Remove header protection** using client_hp key
4. **Re-parse packet structure** with unprotected headers:
   - Version (already known)
   - DCID length + DCID
   - SCID length + SCID
   - Token length + Token (varint)
   - **Length field (varint)** ← Now unprotected, can read correctly
5. **Subtract packet number length** from Length field
6. **Read packet number**
7. **Construct AAD** including packet number: `packet_copy[0..pos]`
8. **Decrypt payload** using correct bounds and AAD

## Common Mistakes

### ❌ Reading Length Before Header Protection Removal
```zig
// WRONG: Length field is still encrypted
const payload_len = readLengthField(data); // Returns 0 or garbage
```

### ❌ Not Subtracting Packet Number Length
```zig
// WRONG: payload_len includes PN, but we use it as payload-only
const encrypted_payload = data[pos..pos + payload_len]; // Off by pn_len bytes
```

### ❌ Excluding Packet Number from AAD
```zig
// WRONG: AAD doesn't include packet number
const header_aad = packet_copy[0..pn_offset]; // Authentication fails
```

## Testing

The implementation was validated using real QUIC packets from `curl --http3-only`:

- **Before fixes:** `error.Truncated` (payload_len = 0)
- **After Fix #1:** `payload_len = 1148` (but still wrong bounds)
- **After Fix #2:** `payload_len = 1147` (correct, but authentication fails)
- **After Fix #3:** `Decrypted 1131 bytes` ✅

## References

- RFC 9001: Using TLS to Secure QUIC
- RFC 9000: QUIC: A UDP-Based Multiplexed and Secure Transport
- Section 17.2: Long Header Packets
- Section 5.3: AEAD Usage

## Implementation Files

- `src/quic/udp_server.zig` - Main packet processing logic
- `src/quic/crypto.zig` - Crypto primitives (HKDF, AES-128-GCM, header protection)

