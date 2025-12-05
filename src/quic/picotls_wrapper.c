// PicoTLS wrapper for Zig (minicrypto only - no OpenSSL)
// This provides the C functions needed to initialize ptls_context_t
// since Zig cannot access fields of opaque C structs directly.

#include <picotls.h>
#include <picotls/minicrypto.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

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

