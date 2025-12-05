# Certificate Loading - Implementation Status

## ✅ Completed

1. **Certificate File Loading Functions** (`src/quic/picotls_wrapper.c`)
   - `blitz_load_certificate_file()` - Loads PEM certificate into memory
   - `blitz_load_private_key_file()` - Loads PEM private key into memory
   - `blitz_ptls_minicrypto_init_with_certs()` - Initializes context with loaded certs

2. **Integration with Server** (`src/quic/udp_server.zig`)
   - `runQuicServer()` now accepts `cert_path` and `key_path` parameters
   - Certificates are loaded before PicoTLS context initialization
   - Proper error handling for missing or invalid certificate files

3. **Command-Line Integration** (`src/main.zig`)
   - Certificate paths are passed from command-line args to server
   - `--cert` and `--key` flags are already supported

## ⚠️ Current Limitation

**PicoTLS Minicrypto doesn't have built-in certificate parsing.**

The certificates are loaded into memory, but configuring them in `ptls_context_t` requires:

1. **Certificate Parsing**: Parse PEM-encoded X509 certificate
2. **Private Key Parsing**: Parse PEM-encoded private key
3. **Context Configuration**: Set `ctx->sign_certificate` with parsed data

### Options for Certificate Configuration

#### Option 1: Minimal ASN.1 Parser (Recommended for pure minicrypto)
- Implement minimal PEM and ASN.1 parsing
- Extract certificate and key data
- Configure PicoTLS context manually
- **Pros**: No external dependencies
- **Cons**: Complex, error-prone

#### Option 2: Hybrid Approach (Pragmatic)
- Use OpenSSL **only** for certificate parsing
- Use minicrypto for all TLS operations
- Parse certificates with OpenSSL, configure PicoTLS
- **Pros**: Reliable, well-tested
- **Cons**: Adds OpenSSL dependency for cert loading only

#### Option 3: Pre-processed Certificates
- Convert certificates to binary format at build time
- Load binary format directly
- **Pros**: Simple loading
- **Cons**: Requires build-time conversion step

## 🎯 Recommended Next Step

**Option 2 (Hybrid)** is the most pragmatic:
- Keep minicrypto for TLS operations (no OpenSSL in production)
- Use OpenSSL only for certificate parsing (one-time setup)
- Minimal code changes
- Reliable certificate handling

## 📝 Implementation Notes

### Current Certificate Storage

Certificates are stored in static buffers:
```c
static char g_cert_pem_data[8192];
static size_t g_cert_pem_len = 0;
static char g_key_pem_data[4096];
static size_t g_key_pem_len = 0;
```

### Next Steps for Full Certificate Support

1. Add OpenSSL certificate parsing functions (if using hybrid approach)
2. Parse PEM data into X509 and EVP_PKEY structures
3. Create `ptls_sign_certificate_t` structure
4. Set `ctx->sign_certificate` in PicoTLS context
5. Test with real certificates

## 🧪 Testing

### Current Status
```bash
# Certificates are loaded but not yet configured
./zig-out/bin/blitz --mode quic --cert cert.pem --key key.pem

# Expected logs:
# [TLS] Loaded certificate from cert.pem
# [TLS] Loaded private key from key.pem
# [TLS] PicoTLS context initialized with certificates
```

### After Full Implementation
```bash
# Handshake should complete successfully
curl --http3-only --insecure https://localhost:8443/

# Expected: Connection established, no TLS errors
```

## 📚 References

- PicoTLS minicrypto limitations
- X509 certificate structure (ASN.1)
- PEM encoding format
- PicoTLS `ptls_sign_certificate_t` structure

