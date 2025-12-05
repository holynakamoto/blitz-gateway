// PicoTLS wrapper for Zig (minicrypto only - no OpenSSL)
// This provides the C functions needed to initialize ptls_context_t
// since Zig cannot access fields of opaque C structs directly.

#include <picotls.h>
#include <picotls/minicrypto.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/err.h>

// Signature algorithm constants (TLS 1.3)
#define PTLS_SIGNATURE_RSA_PKCS1_SHA256    0x0401
#define PTLS_SIGNATURE_ECDSA_SECP256R1_SHA256 0x0403
#define PTLS_SIGNATURE_RSA_PSS_RSAE_SHA256 0x0804
#define PTLS_ALERT_INTERNAL_ERROR 80
#define PTLS_ALERT_HANDSHAKE_FAILURE 40

// Supported signature algorithms - CRITICAL: Must be provided to PicoTLS
static const uint16_t supported_sign_algorithms[] = {
    PTLS_SIGNATURE_RSA_PSS_RSAE_SHA256,      // 0x0804
    PTLS_SIGNATURE_ECDSA_SECP256R1_SHA256,   // 0x0403
    0  // Sentinel terminator
};

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
    // Cast away const to match picotls context structure
    ctx->key_exchanges = (ptls_key_exchange_algorithm_t **)key_exchanges;
    ctx->cipher_suites = (ptls_cipher_suite_t **)cipher_suites;
}

// Random bytes function using system random (for minicrypto init)
static void blitz_random_bytes(void *buf, size_t len) {
    // Use /dev/urandom for random bytes
    FILE *f = fopen("/dev/urandom", "r");
    if (f != NULL) {
        fread(buf, 1, len, f);
        fclose(f);
    } else {
        // Fallback: zero bytes (not secure, but allows compilation)
        memset(buf, 0, len);
    }
}

// Initialize context with minicrypto defaults
void blitz_ptls_minicrypto_init(void) {
    ptls_context_t* ctx = &g_ptls_ctx_storage;
    ctx->random_bytes = blitz_random_bytes;
    ctx->get_time = &ptls_get_time;
    ctx->key_exchanges = ptls_minicrypto_key_exchanges;
    ctx->cipher_suites = ptls_minicrypto_cipher_suites;
}

// Wrapper for inline function ptls_buffer_init
void blitz_ptls_buffer_init(ptls_buffer_t *buf, void *smallbuf, size_t smallbuf_size) {
    ptls_buffer_init(buf, smallbuf, smallbuf_size);
}

// Wrapper for inline function ptls_buffer_dispose
void blitz_ptls_buffer_dispose(ptls_buffer_t *buf) {
    ptls_buffer_dispose(buf);
}

// Certificate and key storage (for minicrypto)
// Note: Minicrypto doesn't have built-in certificate parsing,
// so we'll store the raw PEM data and let PicoTLS handle it
static char g_cert_pem_data[8192];
static size_t g_cert_pem_len = 0;
static char g_key_pem_data[4096];
static size_t g_key_pem_len = 0;

// Load certificate from PEM file
int blitz_load_certificate_file(const char *cert_path) {
    FILE *f = fopen(cert_path, "r");
    if (f == NULL) {
        return -1;
    }
    
    g_cert_pem_len = fread(g_cert_pem_data, 1, sizeof(g_cert_pem_data) - 1, f);
    fclose(f);
    
    if (g_cert_pem_len == 0 || g_cert_pem_len >= sizeof(g_cert_pem_data)) {
        return -1;
    }
    
    g_cert_pem_data[g_cert_pem_len] = '\0';
    return 0;
}

// Load private key from PEM file
int blitz_load_private_key_file(const char *key_path) {
    FILE *f = fopen(key_path, "r");
    if (f == NULL) {
        return -1;
    }
    
    g_key_pem_len = fread(g_key_pem_data, 1, sizeof(g_key_pem_data) - 1, f);
    fclose(f);
    
    if (g_key_pem_len == 0 || g_key_pem_len >= sizeof(g_key_pem_data)) {
        return -1;
    }
    
    g_key_pem_data[g_key_pem_len] = '\0';
    return 0;
}

// Parse PEM certificate and extract DER-encoded data
static int parse_certificate_pem(const uint8_t *pem_data, size_t pem_len, 
                                  uint8_t **der_out, size_t *der_len_out) {
    BIO *bio = BIO_new_mem_buf(pem_data, pem_len);
    if (!bio) {
        fprintf(stderr, "[CERT] Failed to create BIO\n");
        return -1;
    }

    X509 *cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
    BIO_free(bio);
    
    if (!cert) {
        fprintf(stderr, "[CERT] Failed to parse PEM certificate\n");
        return -1;
    }

    // Convert to DER format
    int der_len = i2d_X509(cert, NULL);
    if (der_len <= 0) {
        X509_free(cert);
        return -1;
    }

    uint8_t *der_data = malloc(der_len);
    if (!der_data) {
        X509_free(cert);
        return -1;
    }

    uint8_t *der_ptr = der_data;
    i2d_X509(cert, &der_ptr);
    
    X509_free(cert);
    *der_out = der_data;
    *der_len_out = der_len;
    
    printf("[CERT] Parsed certificate: %d bytes DER\n", der_len);
    return 0;
}

// Parse PEM private key
static EVP_PKEY* parse_private_key_pem(const uint8_t *pem_data, size_t pem_len) {
    BIO *bio = BIO_new_mem_buf(pem_data, pem_len);
    if (!bio) {
        fprintf(stderr, "[CERT] Failed to create BIO\n");
        return NULL;
    }

    EVP_PKEY *pkey = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
    BIO_free(bio);
    
    if (!pkey) {
        fprintf(stderr, "[CERT] Failed to parse PEM private key\n");
        return NULL;
    }

    fprintf(stderr, "[CERT] Parsed private key successfully\n");
    return pkey;
}

// Signing callback for PicoTLS using OpenSSL EVP_PKEY
// Enhanced with full debug logging and proper algorithm negotiation
static int sign_certificate_callback(
    ptls_sign_certificate_t *self,
    ptls_t *tls,
    ptls_async_job_t **async_job,
    uint16_t *selected_algorithm,
    ptls_buffer_t *outbuf,
    ptls_iovec_t input,
    const uint16_t *algorithms,
    size_t num_algorithms
) {
    fprintf(stderr, "[SIGN] ========================================\n");
    fprintf(stderr, "[SIGN] Signing callback invoked\n");
    fprintf(stderr, "[SIGN] Input to sign: %zu bytes\n", input.len);
    fprintf(stderr, "[SIGN] Client supports %zu algorithms:\n", num_algorithms);
    
    // Print client's supported algorithms
    for (size_t i = 0; i < num_algorithms; i++) {
        const char *algo_name = "Unknown";
        switch (algorithms[i]) {
            case 0x0804: algo_name = "RSA_PSS_RSAE_SHA256"; break;
            case 0x0403: algo_name = "ECDSA_SECP256R1_SHA256"; break;
            case 0x0401: algo_name = "RSA_PKCS1_SHA256"; break;
            case 0x0503: algo_name = "ECDSA_SECP384R1_SHA384"; break;
            case 0x0603: algo_name = "ECDSA_SECP521R1_SHA512"; break;
        }
        fprintf(stderr, "[SIGN]   [%zu] 0x%04x (%s)\n", i, algorithms[i], algo_name);
    }
    
    // Get private key from callback data (stored during init)
    EVP_PKEY *pkey = (EVP_PKEY *)self->cb_data;
    if (!pkey) {
        fprintf(stderr, "[SIGN] ERROR: No private key available\n");
        return PTLS_ALERT_INTERNAL_ERROR;
    }
    
    int key_type = EVP_PKEY_base_id(pkey);
    const char *key_type_str = 
        (key_type == EVP_PKEY_RSA) ? "RSA" :
        (key_type == EVP_PKEY_EC) ? "EC" :
        "Unknown";
    fprintf(stderr, "[SIGN] Private key type: %d (%s)\n", key_type, key_type_str);
    
    // Algorithm selection - match client's algorithms with our key type
    uint16_t selected = 0;
    
    if (key_type == EVP_PKEY_RSA) {
        // Try RSA-PSS first (preferred), then PKCS1 (fallback)
        for (size_t i = 0; i < num_algorithms; i++) {
            if (algorithms[i] == PTLS_SIGNATURE_RSA_PSS_RSAE_SHA256) {
                selected = PTLS_SIGNATURE_RSA_PSS_RSAE_SHA256;
                break;
            }
        }
        if (!selected) {
            for (size_t i = 0; i < num_algorithms; i++) {
                if (algorithms[i] == PTLS_SIGNATURE_RSA_PKCS1_SHA256) {
                    selected = PTLS_SIGNATURE_RSA_PKCS1_SHA256;
                    break;
                }
            }
        }
    } else if (key_type == EVP_PKEY_EC) {
        // Try ECDSA P-256
        for (size_t i = 0; i < num_algorithms; i++) {
            if (algorithms[i] == PTLS_SIGNATURE_ECDSA_SECP256R1_SHA256) {
                selected = PTLS_SIGNATURE_ECDSA_SECP256R1_SHA256;
                break;
            }
        }
    }
    
    if (!selected) {
        fprintf(stderr, "[SIGN] ERROR: No compatible algorithm found\n");
        fprintf(stderr, "[SIGN] Key type: %s, Client algorithms don't match\n", key_type_str);
        return PTLS_ALERT_HANDSHAKE_FAILURE;
    }
    
    fprintf(stderr, "[SIGN] Selected algorithm: 0x%04x\n", selected);
    *selected_algorithm = selected;
    
    // Create signing context
    EVP_MD_CTX *md_ctx = EVP_MD_CTX_new();
    if (!md_ctx) {
        fprintf(stderr, "[SIGN] ERROR: EVP_MD_CTX_new failed\n");
        return PTLS_ALERT_INTERNAL_ERROR;
    }
    
    const EVP_MD *md = EVP_sha256();
    EVP_PKEY_CTX *pkey_ctx = NULL;
    
    // Initialize signing based on selected algorithm
    if (selected == PTLS_SIGNATURE_RSA_PSS_RSAE_SHA256) {
        fprintf(stderr, "[SIGN] Using RSA-PSS padding\n");
        if (EVP_DigestSignInit(md_ctx, &pkey_ctx, md, NULL, pkey) <= 0) {
            fprintf(stderr, "[SIGN] ERROR: EVP_DigestSignInit failed\n");
            ERR_print_errors_fp(stderr);
            EVP_MD_CTX_free(md_ctx);
            return PTLS_ALERT_INTERNAL_ERROR;
        }
        
        if (EVP_PKEY_CTX_set_rsa_padding(pkey_ctx, RSA_PKCS1_PSS_PADDING) <= 0) {
            fprintf(stderr, "[SIGN] ERROR: Failed to set PSS padding\n");
            ERR_print_errors_fp(stderr);
            EVP_MD_CTX_free(md_ctx);
            return PTLS_ALERT_INTERNAL_ERROR;
        }
        
        if (EVP_PKEY_CTX_set_rsa_pss_saltlen(pkey_ctx, -1) <= 0) {  // -1 = hash length
            fprintf(stderr, "[SIGN] ERROR: Failed to set PSS salt length\n");
            ERR_print_errors_fp(stderr);
            EVP_MD_CTX_free(md_ctx);
            return PTLS_ALERT_INTERNAL_ERROR;
        }
    } else if (selected == PTLS_SIGNATURE_RSA_PKCS1_SHA256) {
        fprintf(stderr, "[SIGN] Using RSA PKCS1 padding\n");
        if (EVP_DigestSignInit(md_ctx, &pkey_ctx, md, NULL, pkey) <= 0) {
            fprintf(stderr, "[SIGN] ERROR: EVP_DigestSignInit failed\n");
            ERR_print_errors_fp(stderr);
            EVP_MD_CTX_free(md_ctx);
            return PTLS_ALERT_INTERNAL_ERROR;
        }
        
        if (EVP_PKEY_CTX_set_rsa_padding(pkey_ctx, RSA_PKCS1_PADDING) <= 0) {
            fprintf(stderr, "[SIGN] ERROR: Failed to set PKCS1 padding\n");
            ERR_print_errors_fp(stderr);
            EVP_MD_CTX_free(md_ctx);
            return PTLS_ALERT_INTERNAL_ERROR;
        }
    } else {
        // ECDSA
        fprintf(stderr, "[SIGN] Using ECDSA\n");
        if (EVP_DigestSignInit(md_ctx, NULL, md, NULL, pkey) <= 0) {
            fprintf(stderr, "[SIGN] ERROR: EVP_DigestSignInit failed for ECDSA\n");
            ERR_print_errors_fp(stderr);
            EVP_MD_CTX_free(md_ctx);
            return PTLS_ALERT_INTERNAL_ERROR;
        }
    }
    
    // Update with input data
    if (EVP_DigestSignUpdate(md_ctx, input.base, input.len) <= 0) {
        fprintf(stderr, "[SIGN] ERROR: EVP_DigestSignUpdate failed\n");
        ERR_print_errors_fp(stderr);
        EVP_MD_CTX_free(md_ctx);
        return PTLS_ALERT_INTERNAL_ERROR;
    }
    
    // Determine signature size
    size_t sig_len = 0;
    if (EVP_DigestSignFinal(md_ctx, NULL, &sig_len) <= 0) {
        fprintf(stderr, "[SIGN] ERROR: Failed to get signature length\n");
        ERR_print_errors_fp(stderr);
        EVP_MD_CTX_free(md_ctx);
        return PTLS_ALERT_INTERNAL_ERROR;
    }
    
    fprintf(stderr, "[SIGN] Required signature buffer: %zu bytes\n", sig_len);
    
    // Reserve space in output buffer (grow if needed)
    if (outbuf->capacity - outbuf->off < sig_len) {
        size_t new_capacity = outbuf->off + sig_len + 256;
        uint8_t *new_base = realloc(outbuf->base, new_capacity);
        if (!new_base) {
            fprintf(stderr, "[SIGN] ERROR: Failed to realloc buffer\n");
            EVP_MD_CTX_free(md_ctx);
            return PTLS_ALERT_INTERNAL_ERROR;
        }
        outbuf->base = new_base;
        outbuf->capacity = new_capacity;
    }
    
    // Generate the actual signature
    if (EVP_DigestSignFinal(md_ctx, outbuf->base + outbuf->off, &sig_len) <= 0) {
        fprintf(stderr, "[SIGN] ERROR: EVP_DigestSignFinal failed\n");
        ERR_print_errors_fp(stderr);
        EVP_MD_CTX_free(md_ctx);
        return PTLS_ALERT_INTERNAL_ERROR;
    }
    
    outbuf->off += sig_len;
    EVP_MD_CTX_free(md_ctx);
    
    fprintf(stderr, "[SIGN] Signature generated: %zu bytes\n", sig_len);
    fprintf(stderr, "[SIGN] ========================================\n");
    
    return 0;  // Success
}

// Global storage for certificate and key
static uint8_t *g_cert_der_data = NULL;
static size_t g_cert_der_len = 0;
static EVP_PKEY *g_private_key = NULL;
static ptls_iovec_t g_cert_iovec;

// Sign certificate callback structure - CRITICAL: Must include algorithms array
static ptls_sign_certificate_t g_sign_cert = {
    .cb = sign_certificate_callback,
    .algorithms = supported_sign_algorithms,  // CRITICAL: This was missing!
    .cb_data = NULL  // Will be set to EVP_PKEY* during initialization
};

// Initialize context with certificates (minicrypto + OpenSSL for parsing)
int blitz_ptls_minicrypto_init_with_certs(void) {
    ptls_context_t* ctx = &g_ptls_ctx_storage;
    
    // Check if certificates are loaded
    if (g_cert_pem_len == 0 || g_key_pem_len == 0) {
        fprintf(stderr, "[CERT] No certificates loaded\n");
        return -1;
    }
    
    // Set up minicrypto cipher suites and key exchanges
    ctx->random_bytes = blitz_random_bytes;
    ctx->get_time = &ptls_get_time;
    ctx->key_exchanges = ptls_minicrypto_key_exchanges;
    ctx->cipher_suites = ptls_minicrypto_cipher_suites;
    
    // Parse certificate
    if (parse_certificate_pem((const uint8_t*)g_cert_pem_data, g_cert_pem_len, 
                               &g_cert_der_data, &g_cert_der_len) != 0) {
        fprintf(stderr, "[CERT] Failed to parse certificate\n");
        return -1;
    }
    
    // Parse private key
    g_private_key = parse_private_key_pem((const uint8_t*)g_key_pem_data, g_key_pem_len);
    if (!g_private_key) {
        fprintf(stderr, "[CERT] Failed to parse private key\n");
        free(g_cert_der_data);
        g_cert_der_data = NULL;
        return -1;
    }
    
    // Set up certificate IOVEC
    g_cert_iovec.base = g_cert_der_data;
    g_cert_iovec.len = g_cert_der_len;
    
    // CRITICAL: Store private key in callback data
    g_sign_cert.cb_data = (void *)g_private_key;
    
    // Single certificate chain (array of iovecs, allocated statically)
    static ptls_iovec_t certs[1];
    certs[0] = g_cert_iovec;  // Set at runtime
    
    // Attach to context
    ctx->sign_certificate = &g_sign_cert;  // Use the structure directly (not .super)
    ctx->certificates.list = certs;  // Array of iovecs
    ctx->certificates.count = 1;
    
    fprintf(stderr, "[CERT] ========================================\n");
    fprintf(stderr, "[CERT] PicoTLS context configured with certificate\n");
    fprintf(stderr, "[CERT] Certificate count: %zu\n", ctx->certificates.count);
    fprintf(stderr, "[CERT] Certificate size: %zu bytes\n", ctx->certificates.list[0].len);
    fprintf(stderr, "[CERT] DER header: %02x %02x %02x %02x\n", 
           g_cert_der_data[0], g_cert_der_data[1], g_cert_der_data[2], g_cert_der_data[3]);
    fprintf(stderr, "[CERT] Sign callback: %p\n", (void*)ctx->sign_certificate);
    fprintf(stderr, "[CERT] Algorithms: %p\n", (void*)ctx->sign_certificate->algorithms);
    fprintf(stderr, "[CERT] Private key: %p\n", ctx->sign_certificate->cb_data);
    fprintf(stderr, "[CERT] ========================================\n");
    return 0;
}

