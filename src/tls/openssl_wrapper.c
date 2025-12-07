// C wrapper for OpenSSL TLS 1.3 functions
// This avoids Zig 0.12.0 compatibility issues with OpenSSL's complex types
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/conf.h>
#include <openssl/bio.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/evp.h>
#include <openssl/ec.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <limits.h>
#include <picotls.h>
#include <picotls/minicrypto.h>

// Global picotls context (allocated in C to avoid Zig opaque struct issues)
static ptls_context_t g_ptls_ctx_storage;

// Get pointer to context
ptls_context_t* blitz_get_ptls_ctx(void) {
    return &g_ptls_ctx_storage;
}

// Helper to initialize ptls_context_t (Zig can't access opaque struct fields)
void blitz_ptls_ctx_init(
    void (*random_bytes)(void *buf, size_t len),
    ptls_get_time_t *get_time,
    const ptls_key_exchange_algorithm_t *const *key_exchanges,
    const ptls_cipher_suite_t *const *cipher_suites) {
    ptls_context_t* ctx = &g_ptls_ctx_storage;
    ctx->random_bytes = random_bytes;
    ctx->get_time = get_time;
    // Cast away const to match picotls context structure (it's safe - we're not modifying)
    ctx->key_exchanges = (ptls_key_exchange_algorithm_t **)key_exchanges;
    ctx->cipher_suites = (ptls_cipher_suite_t **)cipher_suites;
}

// Storage for captured TLS secrets (for QUIC key derivation)
static unsigned char g_client_handshake_secret[48];
static unsigned char g_server_handshake_secret[48];
static unsigned char g_client_traffic_secret[48];
static unsigned char g_server_traffic_secret[48];
static int g_handshake_secrets_available = 0;
static int g_traffic_secrets_available = 0;

// Parse hex string to bytes
static int hex_to_bytes(const char* hex, unsigned char* out, int max_len) {
    int len = 0;
    while (*hex && *(hex+1) && len < max_len) {
        unsigned int byte;
        if (sscanf(hex, "%2x", &byte) != 1) break;
        out[len++] = (unsigned char)byte;
        hex += 2;
    }
    return len;
}

// Keylog callback to capture TLS secrets
static void blitz_keylog_callback(const SSL* ssl, const char* line) {
    // Parse NSS key log format: LABEL <client_random> <secret>
    // We're interested in:
    // - CLIENT_HANDSHAKE_TRAFFIC_SECRET
    // - SERVER_HANDSHAKE_TRAFFIC_SECRET  
    // - CLIENT_TRAFFIC_SECRET_0
    // - SERVER_TRAFFIC_SECRET_0
    
    if (strncmp(line, "CLIENT_HANDSHAKE_TRAFFIC_SECRET ", 32) == 0) {
        const char* secret = strchr(line + 32, ' ');
        if (secret) {
            hex_to_bytes(secret + 1, g_client_handshake_secret, 48);
            g_handshake_secrets_available = 1;
            fprintf(stderr, "[TLS-KEYLOG] Got CLIENT_HANDSHAKE_TRAFFIC_SECRET\n");
        }
    }
    else if (strncmp(line, "SERVER_HANDSHAKE_TRAFFIC_SECRET ", 32) == 0) {
        const char* secret = strchr(line + 32, ' ');
        if (secret) {
            hex_to_bytes(secret + 1, g_server_handshake_secret, 48);
            fprintf(stderr, "[TLS-KEYLOG] Got SERVER_HANDSHAKE_TRAFFIC_SECRET\n");
        }
    }
    else if (strncmp(line, "CLIENT_TRAFFIC_SECRET_0 ", 24) == 0) {
        const char* secret = strchr(line + 24, ' ');
        if (secret) {
            hex_to_bytes(secret + 1, g_client_traffic_secret, 48);
            g_traffic_secrets_available = 1;
            fprintf(stderr, "[TLS-KEYLOG] Got CLIENT_TRAFFIC_SECRET_0 (1-RTT)\n");
        }
    }
    else if (strncmp(line, "SERVER_TRAFFIC_SECRET_0 ", 24) == 0) {
        const char* secret = strchr(line + 24, ' ');
        if (secret) {
            hex_to_bytes(secret + 1, g_server_traffic_secret, 48);
            fprintf(stderr, "[TLS-KEYLOG] Got SERVER_TRAFFIC_SECRET_0 (1-RTT)\n");
        }
    }
}

// Get handshake secrets for QUIC key derivation
int blitz_get_handshake_secrets(unsigned char* client_secret, unsigned char* server_secret) {
    if (!g_handshake_secrets_available) return 0;
    memcpy(client_secret, g_client_handshake_secret, 48);
    memcpy(server_secret, g_server_handshake_secret, 48);
    return 1;
}

// Get traffic secrets for 1-RTT
int blitz_get_traffic_secrets(unsigned char* client_secret, unsigned char* server_secret) {
    if (!g_traffic_secrets_available) return 0;
    memcpy(client_secret, g_client_traffic_secret, 48);
    memcpy(server_secret, g_server_traffic_secret, 48);
    return 1;
}

// Check if handshake secrets are available
int blitz_handshake_secrets_available(void) {
    return g_handshake_secrets_available;
}

// Initialize OpenSSL
int blitz_openssl_init(void) {
    OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, NULL);
    return 1;
}

// Create SSL context for TLS 1.3 server
SSL_CTX* blitz_ssl_ctx_new(void) {
    const SSL_METHOD* method = TLS_server_method();
    if (method == NULL) {
        return NULL;
    }
    
    SSL_CTX* ctx = SSL_CTX_new(method);
    if (ctx == NULL) {
        return NULL;
    }
    
    // Set minimum version to TLS 1.3
    SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION);
    SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION);
    
    // Set keylog callback to capture secrets for QUIC
    SSL_CTX_set_keylog_callback(ctx, blitz_keylog_callback);
    
    return ctx;
}

// Forward declaration for ALPN callback (must be before use)
static int blitz_alpn_select_callback(SSL* ssl, const unsigned char** out, unsigned char* outlen,
                                      const unsigned char* in, unsigned int inlen, void* arg);

// Set ALPN callback (called after callback is defined)
void blitz_ssl_ctx_set_alpn(SSL_CTX* ctx) {
    if (ctx != NULL) {
        SSL_CTX_set_alpn_select_cb(ctx, blitz_alpn_select_callback, NULL);
    }
}

// ALPN callback for HTTP/2 negotiation
static int blitz_alpn_select_callback(SSL* ssl, const unsigned char** out, unsigned char* outlen,
                               const unsigned char* in, unsigned int inlen, void* arg) {
    // Prefer HTTP/2, fallback to HTTP/1.1
    // Note: OpenSSL expects protocol strings WITHOUT length prefix
    static const unsigned char http2[] = { 'h', '2' };
    static const unsigned char http11[] = { 'h', 't', 't', 'p', '/', '1', '.', '1' };
    
    for (unsigned int i = 0; i < inlen; ) {
        unsigned char len = in[i];
        i++;
        if (i + len > inlen) break;
        
        if (len == 2 && memcmp(&in[i], "h2", 2) == 0) {
            *out = http2;
            *outlen = 2;  // Just the protocol string length, no prefix
            return SSL_TLSEXT_ERR_OK;
        }
        if (len == 8 && memcmp(&in[i], "http/1.1", 8) == 0) {
            *out = http11;
            *outlen = 8;  // Just the protocol string length, no prefix
            return SSL_TLSEXT_ERR_OK;
        }
        i += len;
    }
    
    return SSL_TLSEXT_ERR_NOACK;
}

// Load certificate and key
int blitz_ssl_ctx_use_certificate_file(SSL_CTX* ctx, const char* cert_file) {
    return SSL_CTX_use_certificate_file(ctx, cert_file, SSL_FILETYPE_PEM);
}

int blitz_ssl_ctx_use_privatekey_file(SSL_CTX* ctx, const char* key_file) {
    return SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM);
}

// Create SSL object for a connection
SSL* blitz_ssl_new(SSL_CTX* ctx) {
    return SSL_new(ctx);
}

// Set file descriptor for SSL (socket BIO - deprecated for io_uring)
int blitz_ssl_set_fd(SSL* ssl, int fd) {
    return SSL_set_fd(ssl, fd);
}

// Create memory BIOs for io_uring integration
BIO* blitz_bio_new_mem_buf(const void* buf, int len) {
    return BIO_new_mem_buf(buf, len);
}

BIO* blitz_bio_new(void) {
    return BIO_new(BIO_s_mem());
}

// Set BIOs for SSL (replaces SSL_set_fd for memory BIOs)
void blitz_ssl_set_bio(SSL* ssl, BIO* rbio, BIO* wbio) {
    SSL_set_bio(ssl, rbio, wbio);
}

// Write data to memory BIO (feed encrypted data from io_uring)
int blitz_bio_write(BIO* bio, const void* buf, int len) {
    return BIO_write(bio, buf, len);
}

// Read data from memory BIO (extract encrypted data for io_uring)
int blitz_bio_read(BIO* bio, void* buf, int len) {
    return BIO_read(bio, buf, len);
}

// Get pending bytes in BIO
int blitz_bio_ctrl_pending(BIO* bio) {
    return BIO_ctrl_pending(bio);
}

// Free BIO
void blitz_bio_free(BIO* bio) {
    if (bio != NULL) {
        BIO_free(bio);
    }
}

// Accept TLS handshake (non-blocking)
int blitz_ssl_accept(SSL* ssl) {
    return SSL_accept(ssl);
}

// Get SSL error
int blitz_ssl_get_error(SSL* ssl, int ret) {
    return SSL_get_error(ssl, ret);
}

// Check if we need to read/write more
int blitz_ssl_want_read(int err) {
    return err == SSL_ERROR_WANT_READ;
}

int blitz_ssl_want_write(int err) {
    return err == SSL_ERROR_WANT_WRITE;
}

// Read encrypted data
int blitz_ssl_read(SSL* ssl, void* buf, int num) {
    return SSL_read(ssl, buf, num);
}

// Write encrypted data
int blitz_ssl_write(SSL* ssl, const void* buf, int num) {
    return SSL_write(ssl, buf, num);
}

// Get negotiated protocol (ALPN)
void blitz_ssl_get_alpn_selected(SSL* ssl, const unsigned char** data, unsigned int* len) {
    SSL_get0_alpn_selected(ssl, data, len);
}

// Free SSL object
void blitz_ssl_free(SSL* ssl) {
    SSL_free(ssl);
}

// Free SSL context
void blitz_ssl_ctx_free(SSL_CTX* ctx) {
    SSL_CTX_free(ctx);
}

// Get error string
const char* blitz_ssl_error_string(void) {
    return ERR_error_string(ERR_get_error(), NULL);
}

// Storage for sign certificate (needed for minicrypto)
static ptls_minicrypto_secp256r1sha256_sign_certificate_t g_sign_cert;
// Storage for certificate DER (needed to keep it alive)
static unsigned char* g_cert_der = NULL;

// Load certificate and key from PEM buffers and set on picotls context
// Returns 0 on success, non-zero on error
int blitz_ptls_load_certificate(const unsigned char* cert_pem, size_t cert_len,
                                const unsigned char* key_pem, size_t key_len) {
    ptls_context_t* ctx = &g_ptls_ctx_storage;

    // Check bounds to prevent truncation when casting size_t to int
    if (cert_len > INT_MAX) {
        fprintf(stderr, "Certificate PEM buffer too large: %zu bytes (max: %d)\n", cert_len, INT_MAX);
        return -11;
    }

    // Parse certificate from PEM
    BIO* cert_bio = BIO_new_mem_buf(cert_pem, (int)cert_len);
    if (cert_bio == NULL) {
        return -1;
    }
    
    X509* cert = PEM_read_bio_X509(cert_bio, NULL, NULL, NULL);
    BIO_free(cert_bio);
    if (cert == NULL) {
        return -2;
    }

    // Check bounds to prevent truncation when casting size_t to int
    if (key_len > INT_MAX) {
        fprintf(stderr, "Private key PEM buffer too large: %zu bytes (max: %d)\n", key_len, INT_MAX);
        X509_free(cert);
        return -12;
    }

    // Parse private key from PEM
    BIO* key_bio = BIO_new_mem_buf(key_pem, (int)key_len);
    if (key_bio == NULL) {
        X509_free(cert);
        return -3;
    }
    
    EVP_PKEY* key = PEM_read_bio_PrivateKey(key_bio, NULL, NULL, NULL);
    BIO_free(key_bio);
    if (key == NULL) {
        X509_free(cert);
        return -4;
    }
    
    // Extract raw private key bytes for minicrypto (secp256r1 only)
    // Minicrypto only supports secp256r1 (P-256) keys
    EC_KEY* ec_key = EVP_PKEY_get1_EC_KEY(key);
    if (ec_key == NULL) {
        EVP_PKEY_free(key);
        X509_free(cert);
        return -5; // Not an EC key or extraction failed
    }
    
    const BIGNUM* priv_key_bn = EC_KEY_get0_private_key(ec_key);
    if (priv_key_bn == NULL) {
        EC_KEY_free(ec_key);
        EVP_PKEY_free(key);
        X509_free(cert);
        return -6;
    }
    
    // Extract the 32-byte private key
    unsigned char priv_key_bytes[32];
    if (BN_bn2binpad(priv_key_bn, priv_key_bytes, 32) != 32) {
        EC_KEY_free(ec_key);
        EVP_PKEY_free(key);
        X509_free(cert);
        return -7;
    }
    
    EC_KEY_free(ec_key);
    EVP_PKEY_free(key);
    
    // Initialize minicrypto sign certificate with raw key bytes
    ptls_iovec_t key_vec = ptls_iovec_init(priv_key_bytes, 32);
    int ret = ptls_minicrypto_init_secp256r1sha256_sign_certificate(&g_sign_cert, key_vec);
    if (ret != 0) {
        X509_free(cert);
        return -8;
    }
    
    // Set sign certificate on context
    ctx->sign_certificate = &g_sign_cert.super;
    
    // Convert certificate to DER format
    unsigned char* cert_der_temp = NULL;
    int cert_der_len = i2d_X509(cert, &cert_der_temp);
    X509_free(cert);
    if (cert_der_len < 0 || cert_der_temp == NULL) {
        return -9;
    }
    
    // Allocate storage for certificate DER (keep it alive)
    if (g_cert_der != NULL) {
        free(g_cert_der);
    }
    g_cert_der = (unsigned char*)malloc(cert_der_len);
    if (g_cert_der == NULL) {
        OPENSSL_free(cert_der_temp);
        return -10;
    }
    memcpy(g_cert_der, cert_der_temp, cert_der_len);
    OPENSSL_free(cert_der_temp);
    
    // Set certificate in context
    static ptls_iovec_t certs[1];
    certs[0].base = g_cert_der;
    certs[0].len = cert_der_len;
    ctx->certificates.list = certs;
    ctx->certificates.count = 1;
    
    return 0;
}

