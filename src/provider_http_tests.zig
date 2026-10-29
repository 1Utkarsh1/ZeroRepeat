const std = @import("std");
const http = @import("provider_http.zig");
const request = @import("provider_request.zig");
const Io = std.Io;
const a = std.testing.allocator;
const io = std.testing.io;
const input: request.Request = .{ .messages = &.{.{ .role = .user, .content = "Offline local fixture 🐈." }} };
const success =
    "data: {\"id\":\"offline-fixture\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"reasoning\":\"Check.\",\"content\":\"OK 🐈\"},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: {\"id\":\"offline-fixture\",\"choices\":[],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":5,\"total_tokens\":105,\"prompt_tokens_details\":{\"cached_tokens\":20},\"completion_tokens_details\":{\"reasoning_tokens\":2}}}\n\n" ++
    "data: [DONE]\n\n";

pub const Fixture = struct {
    server: Io.net.Server,
    seen: std.atomic.Value(u32) = .init(0),
    status: u16 = 200,
    content_type: []const u8 = "text/event-stream; charset=utf-8",
    body: []const u8 = success,
    headers: []const u8 = "",
    chunked: bool = false,
    stall: enum { none, head, body } = .none,
    expected_content: []const u8 = input.messages[0].content.?,

    pub fn init() !Fixture {
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{ .server = try address.listen(io, .{}) };
    }

    pub fn endpoint(self: *Fixture) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/chat/completions", .{self.server.socket.address.getPort()});
    }

    pub fn run(self: *Fixture) anyerror!void {
        const connection = try self.server.accept(io);
        defer connection.close(io);
        var input_buffer: [8192]u8 = undefined;
        var output_buffer: [4096]u8 = undefined;
        var incoming = connection.reader(io, &input_buffer);
        var outgoing = connection.writer(io, &output_buffer);
        var server = std.http.Server.init(&incoming.interface, &outgoing.interface);
        var call = try server.receiveHead();
        try std.testing.expectEqual(std.http.Method.POST, call.head.method);
        try std.testing.expectEqualStrings("/v1/chat/completions", call.head.target);
        var headers = call.iterateHeaders();
        var auth = false;
        var content_type = false;
        var accept = false;
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                try std.testing.expectEqualStrings("Bearer local-fixture", header.value);
                auth = true;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) content_type = std.ascii.eqlIgnoreCase(header.value, "application/json");
            if (std.ascii.eqlIgnoreCase(header.name, "accept")) accept = std.ascii.eqlIgnoreCase(header.value, "text/event-stream");
        }
        try std.testing.expect(auth and content_type and accept);
        var transfer: [1024]u8 = undefined;
        const reader = call.readerExpectNone(&transfer);
        var bytes: [64 * 1024]u8 = undefined;
        const count = try reader.readSliceShort(&bytes);
        try std.testing.expect(count < bytes.len);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes[0..count], .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("stream").?.bool);
        try std.testing.expectEqualStrings("Qwen/Qwen3.8-27B", parsed.value.object.get("model").?.string);
        try std.testing.expectEqualStrings(self.expected_content, parsed.value.object.get("messages").?.array.items[0].object.get("content").?.string);
        _ = self.seen.fetchAdd(1, .release);
        if (self.stall == .head) return io.sleep(.fromSeconds(30), .awake);
        const writer = &outgoing.interface;
        try writer.print("HTTP/1.1 {d} Fixture\r\nContent-Type: {s}\r\nConnection: close\r\n{s}", .{ self.status, self.content_type, self.headers });
        if (self.chunked) {
            try writer.writeAll("Transfer-Encoding: chunked\r\n\r\n");
        } else try writer.print("Content-Length: {d}\r\n\r\n", .{self.body.len});
        if (self.stall == .body) {
            try writer.writeAll(self.body[0..@min(20, self.body.len)]);
            try writer.flush();
            return io.sleep(.fromSeconds(30), .awake);
        }
        if (self.chunked) {
            var offset: usize = 0;
            while (offset < self.body.len) {
                const length = @min(1 + offset % 7, self.body.len - offset);
                try writer.print("{x}\r\n{s}\r\n", .{ length, self.body[offset..][0..length] });
                try writer.flush();
                offset += length;
            }
            try writer.writeAll("0\r\n\r\n");
        } else try writer.writeAll(self.body);
        try writer.flush();
    }
};

fn endpoint(url: []const u8) http.Endpoint {
    return .{ .url = url, .api_key = "local-fixture", .allow_http_loopback = true };
}

test "native HTTP POST consumes fragmented chunked SSE with exact request and usage" {
    var fixture = try Fixture.init();
    defer fixture.server.deinit(io);
    fixture.chunked = true;
    const url = try fixture.endpoint();
    defer a.free(url);
    var serving = try io.concurrent(Fixture.run, .{&fixture});
    defer _ = serving.cancel(io) catch {};
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var outcome = try http.complete(&client, endpoint(url), input, .{ .timeout_ms = 2000 });
    defer outcome.deinit();
    try std.testing.expect(outcome == .reply);
    try std.testing.expectEqualStrings("OK 🐈", outcome.reply.content);
    try std.testing.expectEqualStrings("Check.", outcome.reply.reasoning);
    try std.testing.expectEqual(@as(u64, 100), outcome.reply.usage.?.input_tokens);
    try std.testing.expectEqual(@as(?u64, 20), outcome.reply.usage.?.cached_input_tokens);
    try std.testing.expectEqual(@as(?u64, 2), outcome.reply.usage.?.reasoning_tokens);
    try std.testing.expectEqual(@as(u32, 1), fixture.seen.load(.acquire));
    try serving.await(io);
}

test "HTTP status failures are typed without following redirects or retrying" {
    const cases = [_]struct { status: u16, kind: http.RejectionKind, body: []const u8, headers: []const u8 }{
        .{ .status = 429, .kind = .rate_limit, .body = "{\"error\":{\"message\":\"busy\"}}", .headers = "Retry-After: 7\r\n" },
        .{ .status = 400, .kind = .context_limit, .body = "{\"error\":{\"code\":\"context_length_exceeded\"}}", .headers = "" },
        .{ .status = 401, .kind = .authentication, .body = "{\"error\":{\"message\":\"credential rejected\"}}", .headers = "" },
        .{ .status = 503, .kind = .server, .body = "service unavailable", .headers = "" },
        .{ .status = 307, .kind = .redirect, .body = "", .headers = "Location: http://127.0.0.1:1/never-follow\r\n" },
    };
    for (cases) |case| {
        var fixture = try Fixture.init();
        defer fixture.server.deinit(io);
        fixture.status = case.status;
        fixture.content_type = "application/json";
        fixture.body = case.body;
        fixture.headers = case.headers;
        const url = try fixture.endpoint();
        defer a.free(url);
        var serving = try io.concurrent(Fixture.run, .{&fixture});
        defer _ = serving.cancel(io) catch {};
        var client: std.http.Client = .{ .allocator = a, .io = io };
        defer client.deinit();
        var outcome = try http.complete(&client, endpoint(url), input, .{ .timeout_ms = 2000 });
        defer outcome.deinit();
        try std.testing.expect(outcome == .rejected);
        try std.testing.expectEqual(case.kind, outcome.rejected.kind);
        try std.testing.expectEqual(case.status, outcome.rejected.status);
        try std.testing.expectEqual(if (case.status == 429) @as(?u32, 7) else null, outcome.rejected.retry_after_seconds);
        try std.testing.expectEqual(@as(u32, 1), fixture.seen.load(.acquire));
        try serving.await(io);
    }
}

test "truncated SSE and wrong media type never return a reply" {
    for ([_]bool{ false, true }) |wrong_type| {
        var fixture = try Fixture.init();
        defer fixture.server.deinit(io);
        fixture.body = success[0 .. success.len - "data: [DONE]\n\n".len];
        if (wrong_type) fixture.content_type = "application/json";
        const url = try fixture.endpoint();
        defer a.free(url);
        var serving = try io.concurrent(Fixture.run, .{&fixture});
        defer _ = serving.cancel(io) catch {};
        var client: std.http.Client = .{ .allocator = a, .io = io };
        defer client.deinit();
        try std.testing.expectError(if (wrong_type) error.InvalidContentType else error.TruncatedStream, http.complete(&client, endpoint(url), input, .{ .timeout_ms = 2000 }));
        try serving.await(io);
    }
}

test "one deadline covers both stalled response headers and a stalled streaming body" {
    for ([_]@FieldType(Fixture, "stall"){ .head, .body }) |stall| {
        var fixture = try Fixture.init();
        defer fixture.server.deinit(io);
        fixture.stall = stall;
        const url = try fixture.endpoint();
        defer a.free(url);
        var serving = try io.concurrent(Fixture.run, .{&fixture});
        defer _ = serving.cancel(io) catch {};
        var client: std.http.Client = .{ .allocator = a, .io = io };
        defer client.deinit();
        try std.testing.expectError(error.RequestTimeout, http.complete(&client, endpoint(url), input, .{ .timeout_ms = 200 }));
        try std.testing.expectEqual(@as(u32, 1), fixture.seen.load(.acquire));
        try std.testing.expect(client.connection_pool.used.first == null);
        try std.testing.expectEqual(@as(usize, 0), client.connection_pool.free_len);
    }
}

test "caller cancellation releases an in-flight streaming request and its children" {
    var fixture = try Fixture.init();
    defer fixture.server.deinit(io);
    fixture.stall = .body;
    const url = try fixture.endpoint();
    defer a.free(url);
    var serving = try io.concurrent(Fixture.run, .{&fixture});
    defer _ = serving.cancel(io) catch {};
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var pending = try io.concurrent(http.complete, .{ &client, endpoint(url), input, http.Options{ .timeout_ms = 5000 } });
    defer if (pending.cancel(io)) |result| {
        var owned = result;
        owned.deinit();
    } else |_| {};
    var waits: usize = 0;
    while (fixture.seen.load(.acquire) == 0 and waits < 2000) : (waits += 1) try io.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expectEqual(@as(u32, 1), fixture.seen.load(.acquire));
    try std.testing.expectError(error.Canceled, pending.cancel(io));
    try std.testing.expect(client.connection_pool.used.first == null);
    try std.testing.expectEqual(@as(usize, 0), client.connection_pool.free_len);
}

test "HTTP response size and error-body bounds are enforced independently" {
    {
        var fixture = try Fixture.init();
        defer fixture.server.deinit(io);
        const url = try fixture.endpoint();
        defer a.free(url);
        var serving = try io.concurrent(Fixture.run, .{&fixture});
        defer _ = serving.cancel(io) catch {};
        var client: std.http.Client = .{ .allocator = a, .io = io };
        defer client.deinit();
        try std.testing.expectError(error.ResponseTooLarge, http.complete(&client, endpoint(url), input, .{ .stream_limits = .{ .max_response_bytes = 32 } }));
        try serving.await(io);
    }
    {
        var fixture = try Fixture.init();
        defer fixture.server.deinit(io);
        fixture.status = 429;
        var large: [5000]u8 = @splat('x');
        fixture.body = &large;
        const url = try fixture.endpoint();
        defer a.free(url);
        var serving = try io.concurrent(Fixture.run, .{&fixture});
        defer _ = serving.cancel(io) catch {};
        var client: std.http.Client = .{ .allocator = a, .io = io };
        defer client.deinit();
        var result = try http.complete(&client, endpoint(url), input, .{});
        defer result.deinit();
        try std.testing.expect(result == .rejected);
        try std.testing.expectEqual(http.RejectionKind.rate_limit, result.rejected.kind);
        try std.testing.expect(result.rejected.body_truncated);
        try serving.await(io);
    }
}
