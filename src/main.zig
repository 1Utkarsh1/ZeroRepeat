const std = @import("std");
const builtin = @import("builtin");
const zr = @import("zerorepeat");
const cx = zr.context;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const version = "0.1.0-dev";
const max_body_bytes = 64 * 1024 * 1024;

const attribution =
    "Native Zig adaptation uses billion-context and acp-kernel mechanisms.\n" ++
    "https://github.com/ranxianglei/billion-context\n" ++
    "https://github.com/ranxianglei/acp-kernel\n";

const usage =
    \\ZeroRepeat — native context and project continuity tools (development build)
    \\The complete coding harness is under construction; no agent/model loop is exposed yet.
    \\
    \\Usage:
    \\  zerorepeat help | version | doctor
    \\  zerorepeat continuity check [--release]
    \\  zerorepeat continuity context
    \\  zerorepeat continuity log <title> <text>
    \\  zerorepeat context <db> init | status | compile | recommend
    \\  zerorepeat context <db> add <external-id> <role> <body-file> [kind] [call-id] [tool-name] [group-id] [--pinned]
    \\  zerorepeat context <db> fold <generation> <start-ref> <end-ref> <summary-file> [topic]
    \\  zerorepeat context <db> expand <generation> <bN:vN> [--deep]
    \\  zerorepeat context <db> refold <generation> <bN:vN> <summary-file> [topic]
    \\  zerorepeat context <db> retrieve <ref> [offset] [limit]
    \\  zerorepeat context <db> search <query> [limit]
    \\  zerorepeat context <db> rule <source-mN> <constraint|task|decision|fact> <body-file> [supersedes-id]
    \\  zerorepeat context <db> retire-rule <generation> <rN>
    \\
    \\Roles: system, user, assistant, tool. Kinds: text (default), reasoning, tool_call, tool_result, media.
    \\Refs are mN or bN:vN. Use status/compile for the current generation and live references.
    \\Body files are UTF-8 and at most 64 MiB; summaries/rules have stricter native limits.
    \\Retrieval offsets/limits are bytes; default limit 65536. Exact originals are written without framing.
    \\Disk databases require init first and an existing physical parent path (no symlinks). No directories are created.
    \\Continuity commands operate on the current project directory. --release rejects unfinished required work.
    \\Compile is self-contained; token counts use a conservative byte estimate, not model usage.
    \\No command provisions cloud resources or calls a model. See docs/PLAN.md for the full roadmap.
    \\
;

pub fn main(init: std.process.Init) void {
    var output_buffer: [4096]u8 = undefined;
    var output: Io.File.Writer = .initStreaming(.stdout(), init.io, &output_buffer);
    const failure = run(init, &output.interface);
    output.interface.flush() catch |err| {
        std.debug.print("zerorepeat: output failed ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    failure catch |err| {
        std.debug.print("zerorepeat: {s}. Run `zerorepeat help` for command syntax.\n", .{@errorName(err)});
        if (err == error.Sqlite) std.debug.print("SQLite initialization can fail for missing/symlink parent paths or unavailable FTS5; use a physical path and run doctor.\n", .{});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init, writer: *Io.Writer) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) return writer.writeAll(usage ++ attribution);
    const command = args[1];
    if (oneOf(command, &.{ "help", "--help", "-h" })) {
        if (args.len != 2) return error.InvalidArguments;
        return writer.writeAll(usage ++ attribution);
    }
    if (oneOf(command, &.{ "version", "--version" })) {
        if (args.len != 2) return error.InvalidArguments;
        try writer.print("ZeroRepeat {s}; Zig {s}\nUpstream context reference: {s}\n", .{ version, builtin.zig_version_string, cx.upstream_revision });
        return writer.writeAll(attribution);
    }
    if (std.mem.eql(u8, command, "doctor")) {
        if (args.len != 2) return error.InvalidArguments;
        return doctor(allocator, writer);
    }
    if (std.mem.eql(u8, command, "continuity")) return continuity(allocator, init.io, args[2..], writer);
    if (std.mem.eql(u8, command, "context")) return context(allocator, init.io, args[2..], writer);
    return error.UnknownCommand;
}

fn doctor(allocator: Allocator, writer: *Io.Writer) !void {
    var store = try cx.Context.open(":memory:", .{});
    defer store.close();
    var version_row = try store.database.prepare("SELECT sqlite_version();");
    defer version_row.deinit();
    if (!try version_row.step()) return error.StorageProbeFailed;
    _ = try store.append(allocator, .{ .external_id = "doctor-probe", .role = .user, .body = "ZeroRepeat native storage and search probe." });
    var hits = try store.search(allocator, "probe", 1);
    defer hits.deinit();
    if (hits.hits.len != 1) return error.SearchProbeFailed;
    const compiled = try store.compile(allocator);
    defer allocator.free(compiled.text);
    try writer.print("ZeroRepeat {s}; Zig {s}; {s}/{s}\n", .{ version, builtin.zig_version_string, @tagName(builtin.target.os.tag), @tagName(builtin.target.cpu.arch) });
    try writer.print("SQLite {s}; bundled native library.\n", .{version_row.text(0)});
    try writer.writeAll("PASS: native SQLite context, FTS5 search, and self-contained context compilation.\n" ++
        "The probe used an in-memory database; no project database was changed.\n" ++
        "Reference model: Qwen/Qwen3.8-27B. Model/provider execution is not implemented yet.\n" ++
        "This command created no cloud resources and made no model request. Initial cloud budget remains US$7.\n");
    try writer.writeAll(attribution);
}

fn continuity(allocator: Allocator, io: Io, args: []const [:0]const u8, writer: *Io.Writer) !void {
    if (args.len == 0) return error.InvalidArguments;
    if (std.mem.eql(u8, args[0], "check")) {
        if (args.len > 2 or (args.len == 2 and !std.mem.eql(u8, args[1], "--release"))) return error.InvalidArguments;
        return zr.continuity.check(allocator, io, ".", args.len == 2, writer);
    }
    if (std.mem.eql(u8, args[0], "context")) {
        if (args.len != 1) return error.InvalidArguments;
        return zr.continuity.render(allocator, io, ".", writer);
    }
    if (std.mem.eql(u8, args[0], "log")) {
        if (args.len != 3) return error.InvalidArguments;
        try zr.continuity.appendLog(allocator, io, ".", args[1], args[2]);
        return writer.writeAll("Appended and synchronized docs/LOG.md.\n");
    }
    return error.UnknownContinuityCommand;
}

const Request = union(enum) {
    init,
    status,
    compile,
    recommend,
    add: cx.Message,
    fold: struct { generation: i64, fold: cx.Fold },
    expand: struct { generation: i64, ref: cx.Ref, deep: bool },
    refold: struct { generation: i64, ref: cx.Ref, summary: []const u8, topic: []const u8 },
    retrieve: struct { ref: cx.Ref, offset: usize, limit: usize },
    search: struct { query: []const u8, limit: usize },
    rule: struct { source: i64, kind: cx.RuleKind, body: []const u8, supersedes: ?i64 },
    @"retire-rule": struct { generation: i64, id: i64 },
};

fn context(allocator: Allocator, io: Io, args: []const [:0]const u8, writer: *Io.Writer) !void {
    if (args.len < 2) return error.InvalidArguments;
    const request = try parseRequest(allocator, io, args[1..]);
    const path = args[0];
    if (request != .init and !std.mem.eql(u8, path, ":memory:")) {
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.DatabaseNotInitialized,
            else => return err,
        };
        if (stat.kind != .file) return error.InvalidDatabasePath;
    }
    var store = try cx.Context.open(path, .{});
    defer store.close();
    switch (request) {
        .init => try writer.print("Context ready; generation={d}.\n", .{try store.generation()}),
        .status => {
            const status = try store.status();
            try writer.print("generation={d}\nmessages={d}\nblocks={d}\nactive_blocks={d}\noriginals_bytes={d}\nstored_bytes={d}\nactive_rules={d}\nretrievals={d}\n", .{
                status.generation,      status.messages,     status.blocks, status.active_blocks,
                status.originals_bytes, status.stored_bytes, status.rules,  status.retrievals,
            });
            try writer.print("context_limit={d}\noutput_reserve={d}\ntoken_counter=conservative_byte_estimate\n", .{ store.config.context_limit, store.config.output_reserve });
        },
        .compile => {
            const compiled = try store.compile(allocator);
            defer allocator.free(compiled.text);
            try writer.writeAll(compiled.text);
        },
        .recommend => {
            var recommendations = try store.recommend(allocator);
            defer recommendations.deinit();
            try writer.print("generation={d}\npressure={s}\nvisible_token_estimate={d}\navailable_token_budget={d}\n", .{
                recommendations.generation, @tagName(recommendations.pressure), recommendations.visible_tokens, recommendations.available_tokens,
            });
            for (recommendations.ranges) |candidate| {
                try candidate.start.write(writer);
                try writer.writeAll("..");
                try candidate.end.write(writer);
                try writer.print("; source_messages={d}; token_estimate={d}; next_tier={d}\n", .{ candidate.source_messages, candidate.visible_tokens, candidate.next_tier });
            }
            if (recommendations.ranges.len == 0) try writer.writeAll("No eligible compression range; protected content remains live.\n");
        },
        .add => |message| {
            const id = try store.append(allocator, message);
            try writer.print("m{d}; generation={d}.\n", .{ id, try store.generation() });
        },
        .fold => |input| {
            const ids = try store.foldBatch(allocator, input.generation, &.{input.fold});
            defer allocator.free(ids);
            for (ids) |id| try writer.print("b{d}:v1; generation={d}.\n", .{ id, try store.generation() });
        },
        .expand => |input| {
            try store.expand(input.generation, input.ref, input.deep);
            try writer.writeAll("Expanded ");
            try input.ref.write(writer);
            try writer.print(" ({s}); generation={d}.\n", .{ if (input.deep) "deep" else "shallow", try store.generation() });
        },
        .refold => |input| {
            const ref = try store.refold(allocator, input.generation, input.ref, input.summary, input.topic);
            try ref.write(writer);
            try writer.print("; generation={d}.\n", .{try store.generation()});
        },
        .retrieve => |input| {
            const content = try store.retrieve(allocator, input.ref, input.offset, input.limit);
            defer allocator.free(content);
            try writer.writeAll(content);
        },
        .search => |input| {
            var hits = try store.search(allocator, input.query, input.limit);
            defer hits.deinit();
            for (hits.hits) |hit| {
                try hit.ref.write(writer);
                if (hit.owner_block) |owner| try writer.print(" (folded in b{d})", .{owner});
                try writer.print("\n{s}\n\n", .{hit.excerpt});
            }
            if (hits.hits.len == 0) try writer.writeAll("No matching context.\n");
        },
        .rule => |input| {
            const id = try store.addRule(.user, input.kind, input.source, input.body, input.supersedes);
            try writer.print("r{d}; generation={d}.\n", .{ id, try store.generation() });
        },
        .@"retire-rule" => |input| {
            try store.retireRule(.user, input.generation, input.id);
            try writer.print("Retired r{d}; generation={d}.\n", .{ input.id, try store.generation() });
        },
    }
}

fn parseRequest(allocator: Allocator, io: Io, args: []const [:0]const u8) !Request {
    if (args.len == 0) return error.InvalidArguments;
    const command = std.meta.stringToEnum(std.meta.Tag(Request), args[0]) orelse return error.UnknownContextCommand;
    const params = args[1..];
    switch (command) {
        .init, .status, .compile, .recommend => {
            if (params.len != 0) return error.InvalidArguments;
            return switch (command) {
                .init => .init,
                .status => .status,
                .compile => .compile,
                .recommend => .recommend,
                else => unreachable,
            };
        },
        .add => {
            if (params.len < 3 or params.len > 8) return error.InvalidArguments;
            const role = std.meta.stringToEnum(cx.Role, params[1]) orelse return error.InvalidRole;
            var optional: [4][]const u8 = @splat("");
            var count: usize = 0;
            var pinned = false;
            for (params[3..]) |value| {
                if (std.mem.eql(u8, value, "--pinned")) {
                    if (pinned) return error.InvalidArguments;
                    pinned = true;
                } else {
                    if (count == optional.len or std.mem.startsWith(u8, value, "--")) return error.InvalidArguments;
                    optional[count] = value;
                    count += 1;
                }
            }
            const kind = if (count > 0) std.meta.stringToEnum(cx.Kind, optional[0]) orelse return error.InvalidMessageKind else .text;
            return .{ .add = .{ .external_id = params[0], .role = role, .body = try readBody(allocator, io, params[2]), .kind = kind, .call_id = optional[1], .tool_name = optional[2], .group_id = optional[3], .pinned = pinned } };
        },
        .fold => {
            if (params.len < 4 or params.len > 5) return error.InvalidArguments;
            return .{ .fold = .{ .generation = try nonnegative(params[0]), .fold = .{ .start = try reference(params[1]), .end = try reference(params[2]), .summary = try readBody(allocator, io, params[3]), .topic = if (params.len == 5) params[4] else "" } } };
        },
        .expand => {
            if (params.len < 2 or params.len > 3 or (params.len == 3 and !std.mem.eql(u8, params[2], "--deep"))) return error.InvalidArguments;
            const ref = try reference(params[1]);
            if (ref.kind != .block) return error.BlockReferenceRequired;
            return .{ .expand = .{ .generation = try nonnegative(params[0]), .ref = ref, .deep = params.len == 3 } };
        },
        .refold => {
            if (params.len < 3 or params.len > 4) return error.InvalidArguments;
            const ref = try reference(params[1]);
            if (ref.kind != .block) return error.BlockReferenceRequired;
            return .{ .refold = .{ .generation = try nonnegative(params[0]), .ref = ref, .summary = try readBody(allocator, io, params[2]), .topic = if (params.len == 4) params[3] else "" } };
        },
        .retrieve => {
            if (params.len < 1 or params.len > 3) return error.InvalidArguments;
            const limit = if (params.len == 3) try unsigned(params[2]) else 64 * 1024;
            if (limit == 0 or limit > 64 * 1024) return error.InvalidRetrievalLimit;
            return .{ .retrieve = .{ .ref = try reference(params[0]), .offset = if (params.len >= 2) try unsigned(params[1]) else 0, .limit = limit } };
        },
        .search => {
            if (params.len < 1 or params.len > 2) return error.InvalidArguments;
            const limit = if (params.len == 2) try unsigned(params[1]) else 10;
            if (limit == 0 or limit > 100) return error.InvalidSearchLimit;
            return .{ .search = .{ .query = params[0], .limit = limit } };
        },
        .rule => {
            if (params.len < 3 or params.len > 4) return error.InvalidArguments;
            const source = try cx.Ref.parse(params[0]);
            if (source.kind != .message) return error.MessageReferenceRequired;
            const kind = std.meta.stringToEnum(cx.RuleKind, params[1]) orelse return error.InvalidRuleKind;
            const supersedes = if (params.len == 4) try ruleId(params[3]) else null;
            return .{ .rule = .{ .source = source.id, .kind = kind, .body = try readBody(allocator, io, params[2]), .supersedes = supersedes } };
        },
        .@"retire-rule" => {
            if (params.len != 2) return error.InvalidArguments;
            return .{ .@"retire-rule" = .{ .generation = try nonnegative(params[0]), .id = try ruleId(params[1]) } };
        },
    }
}

fn readBody(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    const body = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_body_bytes + 1));
    errdefer allocator.free(body);
    if (body.len > max_body_bytes) return error.BodyTooLarge;
    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidUtf8;
    return body;
}

fn reference(text: []const u8) !cx.Ref {
    const ref = try cx.Ref.parse(text);
    if (ref.kind == .block and ref.version == null) return error.BlockVersionRequired;
    return ref;
}

fn unsigned(text: []const u8) !usize {
    if (text.len == 0 or !std.ascii.isDigit(text[0])) return error.InvalidNumber;
    return std.fmt.parseInt(usize, text, 10) catch error.InvalidNumber;
}

fn nonnegative(text: []const u8) !i64 {
    const value = try unsigned(text);
    return std.math.cast(i64, value) orelse error.InvalidNumber;
}

fn ruleId(text: []const u8) !i64 {
    const id = nonnegative(if (std.mem.startsWith(u8, text, "r")) text[1..] else text) catch return error.InvalidRuleId;
    if (id == 0) return error.InvalidRuleId;
    return id;
}

fn oneOf(text: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, text, choice)) return true;
    return false;
}

test "CLI numbers reject negatives overflow and arbitrary text" {
    try std.testing.expectEqual(@as(i64, 0), try nonnegative("0"));
    try std.testing.expectEqual(@as(usize, 65536), try unsigned("65536"));
    for ([_][]const u8{ "", "-1", "+1", "one", "184467440737095516160" }) |value| try std.testing.expectError(error.InvalidNumber, unsigned(value));
}

test "CLI block references require versions and unknown commands fail before storage opens" {
    try std.testing.expectError(error.BlockVersionRequired, reference("b1"));
    try std.testing.expectEqual(@as(?i64, 2), (try reference("b1:v2")).version);
    try std.testing.expectError(error.UnknownContextCommand, parseRequest(std.testing.allocator, std.testing.io, &.{"does-not-exist"}));
    try std.testing.expectError(error.InvalidArguments, parseRequest(std.testing.allocator, std.testing.io, &.{ "status", "extra" }));
    try std.testing.expectError(error.InvalidRetrievalLimit, parseRequest(std.testing.allocator, std.testing.io, &.{ "retrieve", "m1", "0", "0" }));
    try std.testing.expectError(error.InvalidRuleId, parseRequest(std.testing.allocator, std.testing.io, &.{ "retire-rule", "1", "r0" }));
    try std.testing.expectEqual(@as(i64, 2), (try parseRequest(std.testing.allocator, std.testing.io, &.{ "retire-rule", "1", "r2" })).@"retire-rule".id);
}
