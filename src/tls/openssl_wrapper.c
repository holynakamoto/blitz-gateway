// C wrapper for OpenSSL TLS 1.3 functions
// This avoids Zig 0.12.0 compatibility issues with OpenSSL's complex types

#define _GNU_SOURCE
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/conf.h>
#include <string.h>
#include <unistd.h>

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
    static const unsigned char http2[] = { 2, 'h', '2' };
    static const unsigned char http11[] = { 8, 'h', 't', 't', 'p', '/', '1', '.', '1' };
    
    for (unsigned int i = 0; i < inlen; ) {
        unsigned char len = in[i];
        i++;
        if (i + len > inlen) break;
        
        if (len == 2 && memcmp(&in[i], "h2", 2) == 0) {
            *out = http2;
            *outlen = 3;
            return SSL_TLSEXT_ERR_OK;
        }
        if (len == 8 && memcmp(&in[i], "http/1.1", 8) == 0) {
            *out = http11;
            *outlen = 9;
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

// Set file descriptor for SSL
int blitz_ssl_set_fd(SSL* ssl, int fd) {
    return SSL_set_fd(ssl, fd);
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

