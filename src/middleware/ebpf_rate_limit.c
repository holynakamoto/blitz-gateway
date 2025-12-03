// eBPF program for rate limiting
// This implements a simple token bucket algorithm in eBPF

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

// Rate limiting configuration (updated from userspace)
struct rate_limit_config {
    __u32 global_rps;      // Global rate limit
    __u32 per_ip_rps;      // Per-IP rate limit
    __u32 window_seconds;  // Time window for rate limiting
};

// Token bucket state for each IP
struct token_bucket {
    __u64 tokens;          // Current token count
    __u64 last_update;     // Last update timestamp (nanoseconds)
};

// eBPF maps
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);  // Max tracked IPs
    __type(key, __u32);         // IPv4 address
    __type(value, struct token_bucket);
} ip_buckets SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct rate_limit_config);
} config_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct token_bucket);
} global_bucket SEC(".maps");

// Get current time in nanoseconds
static __always_inline __u64 get_time_ns(void) {
    return bpf_ktime_get_ns();
}

// Refill tokens for a bucket
static __always_inline void refill_tokens(struct token_bucket *bucket,
                                         __u32 rate_per_second,
                                         __u64 now_ns) {
    __u64 time_diff_ns = now_ns - bucket->last_update;
    __u64 time_diff_seconds = time_diff_ns / 1000000000ULL;

    if (time_diff_seconds > 0) {
        __u64 tokens_to_add = time_diff_seconds * rate_per_second;
        __u64 max_tokens = rate_per_second * 2; // Burst allowance

        if (bucket->tokens < max_tokens) {
            bucket->tokens += tokens_to_add;
            if (bucket->tokens > max_tokens) {
                bucket->tokens = max_tokens;
            }
        }
        bucket->last_update = now_ns;
    }
}

// Check if packet should be rate limited
static __always_inline int check_rate_limit(__u32 src_ip) {
    struct rate_limit_config *config;
    __u32 config_key = 0;

    // Get configuration
    config = bpf_map_lookup_elem(&config_map, &config_key);
    if (!config) {
        return XDP_PASS; // No config, allow packet
    }

    __u64 now_ns = get_time_ns();
    int drop_packet = 0;

    // Check global rate limit first
    if (config->global_rps > 0) {
        struct token_bucket *global = bpf_map_lookup_elem(&global_bucket, &config_key);
        if (global) {
            refill_tokens(global, config->global_rps, now_ns);
            if (global->tokens > 0) {
                global->tokens--;
                // Update global bucket
                bpf_map_update_elem(&global_bucket, &config_key, global, BPF_ANY);
            } else {
                drop_packet = 1; // Global limit exceeded
            }
        }
    }

    // Check per-IP rate limit
    if (!drop_packet && config->per_ip_rps > 0) {
        struct token_bucket *ip_bucket = bpf_map_lookup_elem(&ip_buckets, &src_ip);
        if (!ip_bucket) {
            // Create new bucket for this IP
            struct token_bucket new_bucket = {
                .tokens = config->per_ip_rps * 2, // Start with burst allowance
                .last_update = now_ns,
            };
            bpf_map_update_elem(&ip_buckets, &src_ip, &new_bucket, BPF_NOEXIST);
            ip_bucket = bpf_map_lookup_elem(&ip_buckets, &src_ip);
        }

        if (ip_bucket) {
            refill_tokens(ip_bucket, config->per_ip_rps, now_ns);
            if (ip_bucket->tokens > 0) {
                ip_bucket->tokens--;
                // Update IP bucket
                bpf_map_update_elem(&ip_buckets, &src_ip, ip_bucket, BPF_ANY);
            } else {
                drop_packet = 1; // Per-IP limit exceeded
            }
        }
    }

    return drop_packet ? XDP_DROP : XDP_PASS;
}

// XDP program entry point
SEC("xdp")
int xdp_rate_limit(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;

    // Parse Ethernet header
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) {
        return XDP_PASS;
    }

    // Check if IPv4 packet
    if (eth->h_proto != bpf_htons(ETH_P_IP)) {
        return XDP_PASS; // Not IPv4, allow
    }

    // Parse IP header
    struct iphdr *iph = (void *)eth + sizeof(*eth);
    if ((void *)(iph + 1) > data_end) {
        return XDP_PASS;
    }

    // Check if UDP packet (for QUIC)
    if (iph->protocol != IPPROTO_UDP) {
        return XDP_PASS; // Not UDP, allow
    }

    // Apply rate limiting
    return check_rate_limit(iph->saddr);
}

char _license[] SEC("license") = "GPL";
