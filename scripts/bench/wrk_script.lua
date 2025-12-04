-- Blitz Gateway WRK Benchmark Script
-- Advanced HTTP load testing with multiple scenarios

-- Configuration
local scenarios = {
    {
        name = "homepage_get",
        method = "GET",
        path = "/",
        headers = {
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["User-Agent"] = "Blitz-Benchmark-WRK/1.0"
        },
        weight = 80
    },
    {
        name = "api_status_get",
        method = "GET",
        path = "/api/v1/status",
        headers = {
            ["Accept"] = "application/json",
            ["Authorization"] = "Bearer benchmark-token",
            ["User-Agent"] = "Blitz-Benchmark-WRK/1.0"
        },
        weight = 15
    },
    {
        name = "api_data_post",
        method = "POST",
        path = "/api/v1/data",
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["Authorization"] = "Bearer benchmark-token",
            ["User-Agent"] = "Blitz-Benchmark-WRK/1.0"
        },
        body = [[
{
    "timestamp": "2024-01-01T00:00:00Z",
    "data": {
        "sensor_id": "wrk-sensor-001",
        "temperature": 25.5,
        "humidity": 65.0,
        "pressure": 1013.25
    },
    "metadata": {
        "version": "1.0",
        "source": "wrk-benchmark"
    }
}
        ]],
        weight = 5
    }
}

-- Weighted random selection
local function select_scenario()
    local total_weight = 0
    for _, scenario in ipairs(scenarios) do
        total_weight = total_weight + scenario.weight
    end

    local random = math.random(1, total_weight)
    local cumulative = 0

    for _, scenario in ipairs(scenarios) do
        cumulative = cumulative + scenario.weight
        if random <= cumulative then
            return scenario
        end
    end

    return scenarios[1] -- fallback
end

-- Request function (called for each HTTP request)
function request()
    local scenario = select_scenario()

    -- Build the request
    local req = scenario.method .. " " .. scenario.path .. " HTTP/1.1\r\n"

    -- Add headers
    for key, value in pairs(scenario.headers) do
        req = req .. key .. ": " .. value .. "\r\n"
    end

    -- Add custom headers for tracking
    req = req .. "X-Benchmark-Scenario: " .. scenario.name .. "\r\n"
    req = req .. "X-Benchmark-Timestamp: " .. os.time() .. "\r\n"

    -- Add Host header
    req = req .. "Host: localhost\r\n"

    -- Add body if present
    if scenario.body then
        req = req .. "Content-Length: " .. #scenario.body .. "\r\n"
        req = req .. "\r\n"
        req = req .. scenario.body
    else
        req = req .. "\r\n"
    end

    return req
end

-- Response function (called for each HTTP response)
function response(status, headers, body)
    -- Track response metrics
    if status >= 400 then
        -- Log errors for analysis
        io.stderr:write(string.format("ERROR: %d %s\n", status, body:sub(1, 100)))
    end

    -- Extract custom headers for analysis
    for key, value in pairs(headers) do
        if key == "x-benchmark-scenario" then
            -- Track scenario-specific metrics
            -- This could be used for detailed per-scenario analysis
        end
    end
end

-- Setup function (called once at the beginning)
function setup(thread)
    -- Initialize random seed per thread
    math.randomseed(os.time() + thread:get_id())

    -- Thread-specific setup
    thread:set("requests", 0)
    thread:set("errors", 0)
end

-- Init function (called once per thread)
function init(args)
    -- Global initialization
    -- Can access command line arguments here
end

-- Done function (called once at the end)
function done(summary, latency, requests)
    -- Final reporting
    io.write("=======================================\n")
    io.write("WRK Benchmark Complete\n")
    io.write("=======================================\n")

    -- Summary statistics
    io.write(string.format("Duration: %.2f seconds\n", summary.duration))
    io.write(string.format("Requests: %d\n", summary.requests))
    io.write(string.format("Requests/sec: %.2f\n", summary.requests / summary.duration))

    -- Latency statistics
    io.write(string.format("Latency - Mean: %.3f ms\n", latency.mean / 1000))
    io.write(string.format("Latency - Stdev: %.3f ms\n", latency.stdev / 1000))
    io.write(string.format("Latency - Max: %.3f ms\n", latency.max / 1000))
    io.write(string.format("Latency - Percentiles:\n"))
    io.write(string.format("  50%%: %.3f ms\n", latency:percentile(50) / 1000))
    io.write(string.format("  90%%: %.3f ms\n", latency:percentile(90) / 1000))
    io.write(string.format("  95%%: %.3f ms\n", latency:percentile(95) / 1000))
    io.write(string.format("  99%%: %.3f ms\n", latency:percentile(99) / 1000))
    io.write(string.format("  99.9%%: %.3f ms\n", latency:percentile(99.9) / 1000))

    -- Error analysis
    local error_rate = 0
    if summary.requests > 0 then
        error_rate = (summary.errors.status_errors + summary.errors.timeout_errors) / summary.requests * 100
    end
    io.write(string.format("Error Rate: %.2f%%\n", error_rate))

    -- Bytes transferred
    io.write(string.format("Bytes transferred: %d\n", summary.bytes))
    io.write(string.format("Transfer rate: %.2f MB/sec\n", summary.bytes / summary.duration / 1024 / 1024))

    io.write("=======================================\n")

    -- Custom analysis
    analyze_responses(summary, latency, requests)
end

-- Custom response analysis
function analyze_responses(summary, latency, requests)
    io.write("\nCustom Analysis:\n")

    -- Throughput analysis
    local rps = summary.requests / summary.duration
    if rps > 10000 then
        io.write("✅ Excellent throughput: >10k req/sec\n")
    elseif rps > 5000 then
        io.write("✅ Good throughput: >5k req/sec\n")
    elseif rps > 1000 then
        io.write("⚠️ Moderate throughput: >1k req/sec\n")
    else
        io.write("❌ Low throughput: <1k req/sec\n")
    end

    -- Latency analysis
    local p95 = latency:percentile(95) / 1000
    if p95 < 10 then
        io.write("✅ Excellent latency: P95 <10ms\n")
    elseif p95 < 50 then
        io.write("✅ Good latency: P95 <50ms\n")
    elseif p95 < 100 then
        io.write("⚠️ Moderate latency: P95 <100ms\n")
    else
        io.write("❌ High latency: P95 >100ms\n")
    end

    -- Error rate analysis
    local error_rate = 0
    if summary.requests > 0 then
        error_rate = (summary.errors.status_errors + summary.errors.timeout_errors) / summary.requests * 100
    end

    if error_rate < 0.1 then
        io.write("✅ Excellent reliability: Error rate <0.1%\n")
    elseif error_rate < 1.0 then
        io.write("✅ Good reliability: Error rate <1%\n")
    elseif error_rate < 5.0 then
        io.write("⚠️ Moderate reliability: Error rate <5%\n")
    else
        io.write("❌ Poor reliability: Error rate >5%\n")
    end

    io.write("\nRecommendations:\n")

    if rps < 5000 then
        io.write("- Consider optimizing server configuration\n")
        io.write("- Check system resources (CPU, memory, network)\n")
    end

    if p95 > 50 then
        io.write("- Review latency bottlenecks\n")
        io.write("- Consider connection pooling\n")
        io.write("- Check for blocking operations\n")
    end

    if error_rate > 1.0 then
        io.write("- Investigate error causes\n")
        io.write("- Check server logs for issues\n")
        io.write("- Verify endpoint availability\n")
    end
end

-- Helper function to format time
function format_time(microseconds)
    if microseconds < 1000 then
        return string.format("%.1f µs", microseconds)
    elseif microseconds < 1000000 then
        return string.format("%.1f ms", microseconds / 1000)
    else
        return string.format("%.2f s", microseconds / 1000000)
    end
end

-- Helper function to format bytes
function format_bytes(bytes)
    local units = {"B", "KB", "MB", "GB", "TB"}
    local unit_index = 1
    local size = bytes

    while size >= 1024 and unit_index < #units do
        size = size / 1024
        unit_index = unit_index + 1
    end

    return string.format("%.2f %s", size, units[unit_index])
end
