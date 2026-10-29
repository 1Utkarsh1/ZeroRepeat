const std = @import("std");
const context = @import("context.zig");
const provider = @import("provider_stream.zig");
const tools = @import("context_tools.zig");
const request = @import("provider_request.zig");
const a = std.testing.allocator;

test "registered native context schemas are encoded with only their implemented capabilities" {
    const body = try request.encode(a, .{ .messages = &.{.{ .role = .user, .content = "Inspect current context." }}, .tools_json = tools.tool_definitions }, .{});
    defer a.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const definitions = parsed.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), definitions.len);
    try std.testing.expectEqualStrings("inspect", definitions[0].object.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("act", definitions[1].object.get("function").?.object.get("name").?.string);
}

fn toolStream(name: []const u8, arguments: []const u8) ![]u8 {
    const chunk = try std.json.Stringify.valueAlloc(a, .{
        .id = "local-protocol-fixture",
        .choices = .{.{
            .index = @as(u32, 0),
            .delta = .{ .tool_calls = .{.{
                .index = @as(u32, 0),
                .id = "call-fixture",
                .type = "function",
                .function = .{ .name = name, .arguments = arguments },
            }} },
            .finish_reason = "tool_calls",
        }},
    }, .{});
    defer a.free(chunk);
    return std.fmt.allocPrint(a, "data: {s}\n\ndata: [DONE]\n\n", .{chunk});
}

fn decode(wire: []const u8) !provider.Reply {
    var decoder = try provider.Decoder.init(a, .{});
    defer decoder.deinit();
    for (wire) |byte| try decoder.feed(&.{byte});
    return decoder.finish();
}

test "fragmented provider tool calls dispatch native folds and exact retrieval without a proxy" {
    var ctx = try context.Context.open(":memory:", .{ .preserve_recent_messages = 0, .preserve_recent_tokens = 0 });
    defer ctx.close();
    var source: [8192]u8 = @splat('x');
    const nonce = "original-only-nonce-51f4";
    @memcpy(source[101..][0..nonce.len], nonce);
    _ = try ctx.append(a, .{ .external_id = "source", .role = .assistant, .body = &source });
    _ = try ctx.append(a, .{ .external_id = "current", .role = .user, .body = "Preserve this current requirement and exact historical evidence." });
    const fold_args = try std.json.Stringify.valueAlloc(a, .{
        .op = "context.compress",
        .generation = try ctx.generation(),
        .ranges = .{.{ .start = "m1", .end = "m1", .summary = "Historical diagnostic payload retained for exact retrieval. This summary intentionally omits the original nonce." }},
    }, .{});
    defer a.free(fold_args);
    const fold_wire = try toolStream("act", fold_args);
    defer a.free(fold_wire);
    var fold_reply = try decode(fold_wire);
    defer fold_reply.deinit();
    try std.testing.expectEqual(@as(usize, 1), fold_reply.tools.len);
    var acknowledgement = try tools.dispatch(&ctx, a, .{ .name = fold_reply.tools[0].name, .arguments = fold_reply.tools[0].arguments });
    defer acknowledgement.deinit(a);
    try std.testing.expect(acknowledgement.mutating);
    try std.testing.expectEqual(@as(i64, 3), acknowledgement.generation);
    const before = try ctx.compile(a);
    defer a.free(before.text);
    try std.testing.expect(std.mem.indexOf(u8, before.text, nonce) == null);
    const retrieve_wire = try toolStream("inspect", "{\"op\":\"context.retrieve\",\"ref\":\"m1\"}");
    defer a.free(retrieve_wire);
    var retrieve_reply = try decode(retrieve_wire);
    defer retrieve_reply.deinit();
    var result = try tools.dispatch(&ctx, a, .{ .name = retrieve_reply.tools[0].name, .arguments = retrieve_reply.tools[0].arguments });
    defer result.deinit(a);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, result.text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(&source, parsed.value.object.get("content").?.string);
    try std.testing.expect(!result.mutating);
    const after = try ctx.compile(a);
    defer a.free(after.text);
    try std.testing.expectEqualStrings(before.text, after.text);
}

test "truncated and malformed provider replies produce no executable native calls" {
    var ctx = try context.Context.open(":memory:", .{});
    defer ctx.close();
    const initial = try ctx.status();
    const invalid = try toolStream("act", "{\"op\":\"context.compress\"");
    defer a.free(invalid);
    try std.testing.expectError(error.InvalidToolArguments, decode(invalid));
    const valid = try toolStream("inspect", "{\"op\":\"context.status\"}");
    defer a.free(valid);
    const done_at = std.mem.indexOf(u8, valid, "data: [DONE]") orelse unreachable;
    try std.testing.expectError(error.TruncatedStream, decode(valid[0..done_at]));
    try std.testing.expectEqualDeep(initial, try ctx.status());
}
