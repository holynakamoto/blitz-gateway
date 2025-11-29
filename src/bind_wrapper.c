// C wrapper for bind() to avoid Zig 0.12.0 union type issues
#define _GNU_SOURCE  // Must be defined before any includes
#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>  // For AT_FDCWD
#include <liburing.h>

int blitz_bind(int sockfd, const struct sockaddr_in *addr) {
    return bind(sockfd, (const struct sockaddr *)addr, sizeof(struct sockaddr_in));
}

// Wrapper for io_uring_cqe_seen (inline function)
// This ensures the inline function gets properly compiled
void blitz_io_uring_cqe_seen(struct io_uring *ring, struct io_uring_cqe *cqe) {
    io_uring_cqe_seen(ring, cqe);
}

// Wrapper for io_uring_wait_cqe (which uses inline __io_uring_peek_cqe)
int blitz_io_uring_wait_cqe(struct io_uring *ring, struct io_uring_cqe **cqe_ptr) {
    return io_uring_wait_cqe(ring, cqe_ptr);
}

// Wrapper for io_uring_get_sqe to avoid symbol versioning issues
struct io_uring_sqe *blitz_io_uring_get_sqe(struct io_uring *ring) {
    return io_uring_get_sqe(ring);
}

