const std = @import("std");
const context = @import("context.zig");
const task = @import("task.zig");
const agent = @import("agent.zig");
const wire = @import("provider_request.zig");
const stream = @import("provider_stream.zig");
const http = @import("provider_http.zig");
const a = std.testing.allocator;
const io = std.testing.io;

const history_bytes = blk: {
    const text = "Exact historical nonce: q8h2-memory-after-fold. ";
    var bytes: [text.len * 40]u8 = undefined;
    for (0..40) |index| @memcpy(bytes[index * text.len ..][0..text.len], text);
    break :blk bytes;
};
const history = &history_bytes;
const final: task.ReplyRecord = .{ .id = "final", .content = "Ready for independent verification.", .reasoning = "Check retained evidence.", .tools = &.{}, .finish_reason = .stop, .usage = .{ .input_tokens = 120, .output_tokens = 8, .cached_input_tokens = 20, .reasoning_tokens = 3 } };

const Step = struct {
    reply: task.ReplyRecord = final,
    rejection: ?http.Rejection = null,
    delay_ms: u32 = 0,
    failure: ?anyerror = null,
    external_edit: ?*context.Context = null,
    cancel: ?struct { ctx: *context.Context, id: i64 } = null,
};

const Script = struct {
    steps: []const Step,
    seen: std.atomic.Value(u32) = .init(0),
    payloads: std.ArrayList([]u8) = .empty,

    fn provider(self: *Script) agent.Provider {
        return .{ .userdata = self, .call = call };
    }

    fn deinit(self: *Script) void {
        for (self.payloads.items) |bytes| a.free(bytes);
        self.payloads.deinit(a);
    }

    fn call(userdata: *anyopaque, runtime: std.Io, allocator: std.mem.Allocator, input: wire.Request, _: u32) anyerror!http.Outcome {
        const self: *Script = @ptrCast(@alignCast(userdata));
        const index = self.seen.load(.acquire);
        if (index >= self.steps.len) return error.ScriptExhausted;
        const payload = try wire.encode(a, input, .{});
        self.payloads.append(a, payload) catch |err| {
            a.free(payload);
            return err;
        };
        _ = self.seen.fetchAdd(1, .release);
        const step = self.steps[index];
        if (step.delay_ms > 0) try runtime.sleep(.fromMilliseconds(step.delay_ms), .awake);
        if (step.external_edit) |ctx| _ = try ctx.append(a, .{ .external_id = "external-correction", .role = .user, .body = "New user correction while the model was running." });
        if (step.cancel) |request| try (task.Journal{ .ctx = request.ctx }).cancel(request.id);
        if (step.failure) |err| return err;
        if (step.rejection) |rejected| return .{ .rejected = rejected };
        return .{ .reply = try cloneReply(allocator, step.reply) };
    }
};

fn cloneReply(allocator: std.mem.Allocator, record: task.ReplyRecord) !stream.Reply {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const calls = try owned.alloc(stream.ToolCall, record.tools.len);
    for (calls, record.tools) |*out, tool| out.* = .{ .id = try owned.dupe(u8, tool.id), .name = try owned.dupe(u8, tool.name), .arguments = try owned.dupe(u8, tool.arguments) };
    const id = try owned.dupe(u8, record.id);
    const content = try owned.dupe(u8, record.content);
    const reasoning = try owned.dupe(u8, record.reasoning);
    return .{ .arena = arena, .id = id, .content = content, .reasoning = reasoning, .tools = calls, .finish_reason = record.finish_reason, .usage = record.usage };
}

fn config() context.Config {
    return .{ .preserve_recent_messages = 0, .preserve_recent_tokens = 0, .min_range_bytes = 0, .min_summary_bytes = 1, .min_benefit_tokens = 0 };
}

fn fixture() !context.Context {
    var ctx = try context.Context.open(":memory:", config());
    errdefer ctx.close();
    _ = try ctx.append(a, .{ .external_id = "history", .role = .assistant, .body = history });
    _ = try ctx.append(a, .{ .external_id = "objective", .role = .user, .body = "Retain the exact nonce and verify the evidence before completion." });
    return ctx;
}

fn create(ctx: *context.Context, limits: task.Limits) !i64 {
    return (task.Journal{ .ctx = ctx }).create(2, limits);
}

fn toolReply(id: []const u8, calls: []const stream.ToolCall) task.ReplyRecord {
    return .{ .id = id, .content = "", .reasoning = "Inspect the actual retained state.", .tools = calls, .finish_reason = .tool_calls, .usage = .{ .input_tokens = 200, .output_tokens = 12 } };
}

fn compressArgs(generation: i64) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"op\":\"context.compress\",\"generation\":{d},\"ranges\":[{{\"start\":\"m1\",\"end\":\"m1\",\"summary\":\"Historical nonce evidence remains retrievable.\"}}]}}", .{generation});
}

fn number(ctx: *context.Context, sql: [:0]const u8) !i64 {
    return ctx.database.number(sql, &.{});
}

fn commandArgs(exec: *@import("execution.zig").Execution, generation: i64, program: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .op = "exec.run", .scope = exec.scope, .generation = generation, .argv = [_][]const u8{ "/bin/sh", "-c", program }, .timeout_ms = 1000 }, .{});
}

test "shared driver inspects edits tests repairs and retains execution evidence through compaction" {
    const execution_tests = @import("execution_tests.zig");
    const repository = @import("repository.zig");
    var roots = try execution_tests.Roots.init();
    defer roots.deinit();
    try roots.tmp.dir.writeFile(io, .{ .sub_path = "workspace/source", .data = "wrong\n" });
    var ctx = try fixture();
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, roots.workspace, &.{.{ .path = "source", .write = true }});
    defer repo.close();
    var snapshot = try repo.read(a, "source", null);
    defer snapshot.deinit(a);
    var exec = try roots.open(&ctx);
    defer exec.close();
    const id = try create(&ctx, .{});
    const generation = try ctx.generation();
    const first = try std.json.Stringify.valueAlloc(a, .{ .op = "repo.apply", .scope = repo.scope, .generation = generation, .edits = .{.{ .path = "source", .ref = "f1:v1", .replacements = .{.{ .start = 0, .end = 5, .text = "stillwrong" }} }} }, .{});
    defer a.free(first);
    const check = "test \"$(cat source)\" = correct && printf verified-source";
    const failed_test = try commandArgs(&exec, generation + 1, check);
    defer a.free(failed_test);
    const repair = try std.json.Stringify.valueAlloc(a, .{ .op = "repo.apply", .scope = repo.scope, .generation = generation + 3, .edits = .{.{ .path = "source", .ref = "f1:v2", .replacements = .{.{ .start = 0, .end = 10, .text = "correct" }} }} }, .{});
    defer a.free(repair);
    const passed_test = try commandArgs(&exec, generation + 4, check);
    defer a.free(passed_test);
    const fold = try compressArgs(generation + 6);
    defer a.free(fold);
    const read = try std.json.Stringify.valueAlloc(a, .{ .op = "exec.read", .scope = exec.scope, .id = 2, .channel = "stdout" }, .{});
    defer a.free(read);
    var script: Script = .{ .steps = &.{
        .{ .reply = toolReply("policy", &.{.{ .id = "policy", .name = "inspect", .arguments = "{\"op\":\"exec.policy\"}" }}) },
        .{ .reply = toolReply("read", &.{.{ .id = "read", .name = "inspect", .arguments = "{\"op\":\"repo.read\",\"path\":\"source\"}" }}) },
        .{ .reply = toolReply("edit", &.{.{ .id = "edit", .name = "patch", .arguments = first }}) },
        .{ .reply = toolReply("failed-test", &.{.{ .id = "failed-test", .name = "act", .arguments = failed_test }}) },
        .{ .reply = toolReply("repair", &.{.{ .id = "repair", .name = "patch", .arguments = repair }}) },
        .{ .reply = toolReply("passed-test", &.{.{ .id = "passed-test", .name = "act", .arguments = passed_test }}) },
        .{ .reply = toolReply("fold", &.{.{ .id = "fold", .name = "act", .arguments = fold }}) },
        .{ .reply = toolReply("evidence", &.{.{ .id = "evidence", .name = "inspect", .arguments = read }}) },
        .{},
    } };
    defer script.deinit();
    const result = try agent.run(&ctx, a, io, id, script.provider(), .{ .repository = &repo, .execution = &exec });
    try std.testing.expectEqual(task.State.awaiting_verification, result.state);
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM execution_runs WHERE id=1 AND state='finished' AND term_kind='exit' AND term_value=1 AND action_id IS NOT NULL;"));
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM execution_runs WHERE id=2 AND state='finished' AND term_kind='exit' AND term_value=0 AND action_id IS NOT NULL;"));
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[7], "verified-source") != null);
    var projected = try std.json.parseFromSlice(std.json.Value, a, script.payloads.items[7], .{});
    defer projected.deinit();
    var failure_retained = false;
    for (projected.value.object.get("messages").?.array.items) |message| {
        if (!std.mem.eql(u8, message.object.get("role").?.string, "tool")) continue;
        if (std.mem.indexOf(u8, message.object.get("content").?.string, "\"term_value\":1") != null) failure_retained = true;
    }
    try std.testing.expect(failure_retained);
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[8], "exec.read") != null);
    // The independent host checks exact current source and runs a fresh verification.
    var actual = try repo.read(a, "source", null);
    defer actual.deinit(a);
    try std.testing.expectEqualStrings("correct\n", actual.body);
    const verified = try exec.run(a, .{ .generation = try ctx.generation(), .argv = &.{ "/bin/sh", "-c", check }, .timeout_ms = 1000 }, null, null, null);
    try std.testing.expectEqualStrings("exit", verified.term_kind);
    try std.testing.expectEqual(@as(i64, 0), verified.term_value);
}

test "execution preflight cannot grant policy fields and rejects the entire invalid burst before a command" {
    const tools = @import("context_tools.zig");
    var roots = try @import("execution_tests.zig").Roots.init();
    defer roots.deinit();
    var ctx = try fixture();
    defer ctx.close();
    var exec = try roots.open(&ctx);
    defer exec.close();
    const id = try create(&ctx, .{});
    const command = try commandArgs(&exec, try ctx.generation(), "printf once > \"$TMPDIR/counter\"");
    defer a.free(command);
    const escalation = try std.json.Stringify.valueAlloc(a, .{ .op = "exec.run", .scope = exec.scope, .generation = try ctx.generation(), .argv = .{"/bin/true"}, .network = true }, .{});
    defer a.free(escalation);
    var script: Script = .{ .steps = &.{.{ .reply = toolReply("bad-burst", &.{
        .{ .id = "first", .name = "act", .arguments = command },
        .{ .id = "second", .name = "act", .arguments = escalation },
    }) }} };
    defer script.deinit();
    try std.testing.expectError(error.UnknownField, agent.run(&ctx, a, io, id, script.provider(), .{ .execution = &exec }));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM execution_runs;"));
    try std.testing.expectError(error.UnsupportedOperation, tools.prepare(a, .{ .name = "act", .arguments = command }));
    try std.testing.expectError(error.ExecutionMismatch, tools.prepareWithCapabilities(a, .{ .name = "inspect", .arguments = "{\"op\":\"exec.read\",\"scope\":\"other-project\",\"id\":1,\"channel\":\"stdout\"}" }, null, &exec));
    try std.testing.expect(std.mem.indexOf(u8, tools.tool_definitions, "exec.run") == null);
}

test "task deadline reaches the command and failed action acknowledgement never repeats its effect" {
    var roots = try @import("execution_tests.zig").Roots.init();
    defer roots.deinit();
    var ctx = try fixture();
    defer ctx.close();
    var exec = try roots.open(&ctx);
    defer exec.close();
    const id = try create(&ctx, .{ .elapsed_ms = 500 });
    const command = try commandArgs(&exec, try ctx.generation(), "trap '' TERM; while :; do :; done");
    defer a.free(command);
    var script: Script = .{ .steps = &.{.{ .reply = toolReply("timeout", &.{.{ .id = "timeout", .name = "act", .arguments = command }}) }} };
    defer script.deinit();
    try std.testing.expectError(error.TaskTimeout, agent.run(&ctx, a, io, id, script.provider(), .{ .execution = &exec }));
    try std.testing.expectEqual(task.State.budget_exhausted, (try (task.Journal{ .ctx = &ctx }).get(id)).state);
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM execution_runs WHERE state='finished' AND reason='timed_out';"));
    const second = try create(&ctx, .{});
    const once = try commandArgs(&exec, try ctx.generation(), "printf once >> \"$TMPDIR/once\"");
    defer a.free(once);
    try ctx.database.exec("CREATE TRIGGER fail_execution_ack BEFORE UPDATE OF result ON actions BEGIN SELECT RAISE(ABORT,'fixture'); END;");
    var fault: Script = .{ .steps = &.{.{ .reply = toolReply("once", &.{.{ .id = "once", .name = "act", .arguments = once }}) }} };
    defer fault.deinit();
    try std.testing.expectError(error.SqliteConstraint, agent.run(&ctx, a, io, second, fault.provider(), .{ .execution = &exec }));
    try std.testing.expectEqual(task.State.attention, (try (task.Journal{ .ctx = &ctx }).get(second)).state);
    try std.testing.expectError(error.TaskNotPending, agent.run(&ctx, a, io, second, fault.provider(), .{ .execution = &exec }));
    const bytes = try exec.scratch.handle.readFileAlloc(io, "once", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("once", bytes);
}

test "bounded driver folds retrieves and preserves exact read evidence in the next stateless request" {
    var ctx = try fixture();
    defer ctx.close();
    const id = try create(&ctx, .{});
    const args = try compressArgs(try ctx.generation());
    defer a.free(args);
    var script: Script = .{ .steps = &.{
        .{ .reply = toolReply("fold", &.{.{ .id = "reused-provider-id", .name = "act", .arguments = args }}) },
        .{ .reply = toolReply("read", &.{.{ .id = "reused-provider-id", .name = "inspect", .arguments = "{\"op\":\"context.retrieve\",\"ref\":\"m1\",\"limit\":128}" }}) },
        .{},
    } };
    defer script.deinit();
    const result = try agent.run(&ctx, a, io, id, script.provider(), .{});
    try std.testing.expectEqual(task.State.awaiting_verification, result.state);
    try std.testing.expectEqual(@as(u64, 3), result.requests);
    try std.testing.expectEqual(@as(u64, 2), result.tool_calls);
    try std.testing.expectEqual(@as(u64, 1), result.management_rounds);
    try std.testing.expectEqual(@as(u64, 32), result.observed_output_tokens);
    try std.testing.expectEqual(@as(u64, 3), result.usage_known_requests);
    try std.testing.expectEqual(@as(u64, 20), result.observed_cached_input_tokens);
    try std.testing.expectEqual(@as(u64, 3), result.observed_reasoning_tokens);
    try std.testing.expectEqual(@as(u64, 1), result.cached_usage_known_requests);
    try std.testing.expectEqual(@as(i64, 2), (try ctx.status()).messages);
    try std.testing.expectEqual(@as(i64, 2), try number(&ctx, "SELECT count(*) FROM actions WHERE phase='succeeded';"));
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[0], "q8h2-memory-after-fold") != null);
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[1], "q8h2-memory-after-fold") == null);
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[2], "q8h2-memory-after-fold") != null);
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[2], "Historical nonce evidence remains retrievable.") != null);
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[2], "Retain the exact nonce") != null);
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[2], "a2") != null);
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[2], "reused-provider-id") == null);
    try std.testing.expectError(error.TaskNotPending, agent.run(&ctx, a, io, id, script.provider(), .{}));
}

test "host-registered original and corrected requirements remain protected after later user messages" {
    var ctx = try fixture();
    defer ctx.close();
    const journal: task.Journal = .{ .ctx = &ctx };
    const id = try create(&ctx, .{});
    const correction = try ctx.append(a, .{ .external_id = "correction", .role = .user, .body = "Additional obligation: retain raw evidence." });
    try journal.addRequirement(id, correction);
    const generation = try ctx.generation();
    try journal.addRequirement(id, correction);
    try std.testing.expectEqual(generation, try ctx.generation());
    _ = try ctx.append(a, .{ .external_id = "later", .role = .user, .body = "Continue." });
    for ([_]i64{ 2, correction }) |source| try std.testing.expectError(error.ProtectedRange, ctx.foldBatch(a, try ctx.generation(), &.{.{ .start = .{ .kind = .message, .id = source }, .end = .{ .kind = .message, .id = source }, .summary = "Discard requirements." }}));
    try std.testing.expectError(error.InvalidTaskSource, journal.addRequirement(id, 1));
    try journal.cancel(id);
    const ids = try ctx.foldBatch(a, try ctx.generation(), &.{.{ .start = .{ .kind = .message, .id = 2 }, .end = .{ .kind = .message, .id = correction }, .summary = "Explicitly canceled task requirements." }});
    defer a.free(ids);
    try std.testing.expectEqual(@as(usize, 1), ids.len);
}

test "entire invalid tool burst is rejected before any valid preceding mutation starts" {
    var ctx = try fixture();
    defer ctx.close();
    const id = try create(&ctx, .{});
    const args = try compressArgs(try ctx.generation());
    defer a.free(args);
    const before = try ctx.status();
    const before_prompt = try ctx.compile(a);
    defer a.free(before_prompt.text);
    var script: Script = .{ .steps = &.{.{ .reply = toolReply("invalid-burst", &.{
        .{ .id = "first", .name = "act", .arguments = args },
        .{ .id = "last", .name = "patch", .arguments = "{}" },
    }) }} };
    defer script.deinit();
    try std.testing.expectError(error.UnsupportedOperation, agent.run(&ctx, a, io, id, script.provider(), .{}));
    const after = try ctx.status();
    try std.testing.expectEqual(before.generation, after.generation);
    try std.testing.expectEqual(before.messages, after.messages);
    try std.testing.expectEqual(before.blocks, after.blocks);
    const after_prompt = try ctx.compile(a);
    defer a.free(after_prompt.text);
    try std.testing.expectEqualStrings(before_prompt.text, after_prompt.text);
    try std.testing.expect(after.stored_bytes > before.stored_bytes);
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM actions;"));
    try std.testing.expectEqual(task.State.failed, (try (task.Journal{ .ctx = &ctx }).get(id)).state);
}

test "aggregate request tool management wire and output reservations stop work before effects" {
    const cases = [_]task.Limits{
        .{ .requests = 1, .management_rounds = 1 },
        .{ .tool_calls = 0 },
        .{ .management_rounds = 0 },
        .{ .wire_bytes = 1 },
        .{ .output_tokens = 12 },
    };
    for (cases, 0..) |limits, index| {
        var ctx = try fixture();
        defer ctx.close();
        const id = try create(&ctx, limits);
        const args = try compressArgs(try ctx.generation());
        defer a.free(args);
        const use_compress = index == 2;
        var script: Script = .{ .steps = &.{.{ .reply = toolReply("budget", &.{.{ .id = "call", .name = if (use_compress) "act" else "inspect", .arguments = if (use_compress) args else "{\"op\":\"context.status\"}" }}) }} };
        defer script.deinit();
        try std.testing.expectError(error.TaskBudgetExceeded, agent.run(&ctx, a, io, id, script.provider(), .{}));
        const state = try (task.Journal{ .ctx = &ctx }).get(id);
        try std.testing.expectEqual(task.State.budget_exhausted, state.state);
        try std.testing.expectEqual(@as(i64, 0), (try ctx.status()).blocks);
        if (index == 1 or index == 2 or index == 3) try std.testing.expectEqual(@as(u64, 0), state.tool_calls);
        if (index == 3) try std.testing.expectEqual(@as(u64, 0), state.requests);
    }
}

test "missing usage consumes a conservative output reservation without inventing measured tokens" {
    var ctx = try fixture();
    defer ctx.close();
    const id = try create(&ctx, .{ .output_tokens = 100, .output_per_request = 100 });
    var record = toolReply("unknown-usage", &.{.{ .id = "call", .name = "inspect", .arguments = "{\"op\":\"context.status\"}" }});
    record.usage = null;
    var script: Script = .{ .steps = &.{.{ .reply = record }} };
    defer script.deinit();
    try std.testing.expectError(error.TaskBudgetExceeded, agent.run(&ctx, a, io, id, script.provider(), .{}));
    const state = try (task.Journal{ .ctx = &ctx }).get(id);
    try std.testing.expectEqual(@as(u64, 100), state.output_charged);
    try std.testing.expectEqual(@as(u64, 0), state.usage_known_requests);
    try std.testing.expectEqual(@as(u64, 0), state.observed_output_tokens);
}

test "duplicate provider responses and repeated failing operations stop instead of looping" {
    for ([_]bool{ false, true }) |duplicate| {
        var ctx = try fixture();
        defer ctx.close();
        const id = try create(&ctx, .{});
        const first = toolReply("response-one", &.{.{ .id = "same", .name = "inspect", .arguments = "{\"op\":\"context.retrieve\",\"ref\":\"m999\"}" }});
        var second = first;
        if (!duplicate) second.id = "response-two";
        var script: Script = .{ .steps = &.{ .{ .reply = first }, .{ .reply = second } } };
        defer script.deinit();
        try std.testing.expectError(if (duplicate) error.SqliteConstraint else error.RepeatedToolFailure, agent.run(&ctx, a, io, id, script.provider(), .{}));
        try std.testing.expectEqual(@as(i64, if (duplicate) 1 else 2), try number(&ctx, "SELECT count(*) FROM actions;"));
        const state = try (task.Journal{ .ctx = &ctx }).get(id);
        try std.testing.expectEqual(if (duplicate) task.State.attention else task.State.failed, state.state);
        try std.testing.expectError(error.TaskNotPending, agent.run(&ctx, a, io, id, script.provider(), .{}));
    }
}

test "context changes while awaiting a model response invalidate its action generation" {
    var ctx = try fixture();
    defer ctx.close();
    const id = try create(&ctx, .{});
    const args = try compressArgs(try ctx.generation());
    defer a.free(args);
    var script: Script = .{ .steps = &.{.{ .reply = toolReply("stale", &.{.{ .id = "call", .name = "act", .arguments = args }}), .external_edit = &ctx }} };
    defer script.deinit();
    try std.testing.expectError(error.StaleGeneration, agent.run(&ctx, a, io, id, script.provider(), .{}));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM actions;"));
    const compiled = try ctx.compile(a);
    defer a.free(compiled.text);
    try std.testing.expect(std.mem.indexOf(u8, compiled.text, "New user correction") != null);
}

test "task deadline cancels a cooperative provider and records its uncertain request" {
    var ctx = try fixture();
    defer ctx.close();
    const id = try create(&ctx, .{ .elapsed_ms = 100 });
    var script: Script = .{ .steps = &.{.{ .delay_ms = 30_000 }} };
    defer script.deinit();
    try std.testing.expectError(error.TaskTimeout, agent.run(&ctx, a, io, id, script.provider(), .{}));
    const state = try (task.Journal{ .ctx = &ctx }).get(id);
    try std.testing.expectEqual(task.State.attention, state.state);
    try std.testing.expect(state.elapsed_ms >= 100 and state.elapsed_ms < 5000);
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM model_requests WHERE phase='uncertain';"));
    try std.testing.expect(!ctx.database.inTransaction());
}

test "external cancellation joins the provider and never exposes an executable reply" {
    var ctx = try fixture();
    defer ctx.close();
    const id = try create(&ctx, .{});
    var script: Script = .{ .steps = &.{.{ .delay_ms = 30_000 }} };
    defer script.deinit();
    var pending = try io.concurrent(agent.run, .{ &ctx, a, io, id, script.provider(), agent.Options{} });
    defer _ = pending.cancel(io) catch {};
    var waits: usize = 0;
    while (script.seen.load(.acquire) == 0 and waits < 2000) : (waits += 1) try io.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expectEqual(@as(u32, 1), script.seen.load(.acquire));
    try std.testing.expectError(error.Canceled, pending.cancel(io));
    try std.testing.expectEqual(task.State.canceled, (try (task.Journal{ .ctx = &ctx }).get(id)).state);
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM actions;"));
}

test "typed provider rejection persists safe diagnostics once without retries" {
    var ctx = try fixture();
    defer ctx.close();
    const id = try create(&ctx, .{});
    var script: Script = .{ .steps = &.{.{ .rejection = .{ .status = 429, .kind = .rate_limit, .retry_after_seconds = 7 } }} };
    defer script.deinit();
    try std.testing.expectError(error.ProviderRejected, agent.run(&ctx, a, io, id, script.provider(), .{}));
    try std.testing.expectEqual(@as(u32, 1), script.seen.load(.acquire));
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM model_requests WHERE phase='rejected' AND diagnostic LIKE '%rate_limit%';"));
    try std.testing.expectEqual(task.State.failed, (try (task.Journal{ .ctx = &ctx }).get(id)).state);
}

test "configured credentials including JSON escaped arguments are rejected before audit or effects" {
    const key = "fixture-secret-A9";
    for ([_]bool{ false, true }) |arguments| {
        var ctx = try fixture();
        defer ctx.close();
        const id = try create(&ctx, .{});
        var record = final;
        if (arguments) record = toolReply("secret-args", &.{.{ .id = "call", .name = "inspect", .arguments = "{\"op\":\"context.search\",\"query\":\"fixture-\\u0073ecret-A9\"}" }}) else record.reasoning = key;
        var script: Script = .{ .steps = &.{.{ .reply = record }} };
        defer script.deinit();
        var provider = script.provider();
        provider.secret = key;
        try std.testing.expectError(error.SensitiveData, agent.run(&ctx, a, io, id, provider, .{}));
        try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM actions;"));
        try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM blobs WHERE instr(CAST(body AS TEXT),'fixture-secret-A9')>0 OR instr(CAST(body AS TEXT),'fixture-\\u0073ecret-A9')>0;"));
    }
}

test "failed durable result acknowledgement leaves a committed mutation uncertain and unreplayed" {
    var ctx = try fixture();
    defer ctx.close();
    const id = try create(&ctx, .{});
    const args = try compressArgs(try ctx.generation());
    defer a.free(args);
    try ctx.database.exec("CREATE TRIGGER fail_ack BEFORE UPDATE OF result ON actions BEGIN SELECT RAISE(ABORT,'injected acknowledgement failure'); END;");
    var script: Script = .{ .steps = &.{.{ .reply = toolReply("ack-failure", &.{.{ .id = "call", .name = "act", .arguments = args }}) }} };
    defer script.deinit();
    try std.testing.expectError(error.SqliteConstraint, agent.run(&ctx, a, io, id, script.provider(), .{}));
    try std.testing.expectEqual(@as(i64, 1), (try ctx.status()).active_blocks);
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM actions WHERE phase='uncertain';"));
    try std.testing.expectEqual(task.State.attention, (try (task.Journal{ .ctx = &ctx }).get(id)).state);
    try std.testing.expectError(error.TaskNotPending, agent.run(&ctx, a, io, id, script.provider(), .{}));
    try std.testing.expectEqual(@as(u32, 1), script.seen.load(.acquire));
}

fn pathFor(tmp: *std.testing.TmpDir) ![:0]u8 {
    var bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const size = try tmp.dir.realPath(io, &bytes);
    return std.fmt.allocPrintSentinel(a, "{s}/task.sqlite", .{bytes[0..size]}, 0);
}

test "reopen and explicit recovery distinguish never-started actions from committed but unacknowledged effects" {
    for ([_]bool{ false, true }) |started| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try pathFor(&tmp);
        defer a.free(path);
        var id: i64 = 0;
        {
            var ctx = try context.Context.open(path, config());
            defer ctx.close();
            _ = try ctx.append(a, .{ .external_id = "history", .role = .assistant, .body = history });
            _ = try ctx.append(a, .{ .external_id = "objective", .role = .user, .body = "Preserve the uncertain mutation evidence." });
            id = try create(&ctx, .{});
            const journal: task.Journal = .{ .ctx = &ctx };
            try journal.claim(id);
            const payload = try wire.encode(a, .{ .messages = &.{.{ .role = .user, .content = history }} }, .{});
            defer a.free(payload);
            const generation = try ctx.generation();
            const request = try journal.reserveRequest(id, generation, payload, 4096);
            const args = try compressArgs(generation);
            defer a.free(args);
            var reply = try cloneReply(a, toolReply("interrupted-reply", &.{
                .{ .id = "effect", .name = "act", .arguments = args },
                .{ .id = "never-started", .name = "inspect", .arguments = "{\"op\":\"context.status\"}" },
            }));
            defer reply.deinit();
            try journal.recordReply(a, request, reply);
            try journal.planActions(request, reply.tools, &.{ .{ .mutating = true, .management = true }, .{ .mutating = false, .management = false } });
            try std.testing.expectError(error.UnfinishedActions, journal.startAction(request, 1, generation));
            try std.testing.expectError(error.UnfinishedActions, journal.reserveRequest(id, generation, payload, 4096));
            if (started) {
                _ = try journal.startAction(request, 0, generation);
                var result = try @import("context_tools.zig").dispatch(&ctx, a, .{ .name = "act", .arguments = args });
                result.deinit(a);
                // Deliberately omit the acknowledgement at the effect/result crash boundary.
            }
        }
        {
            var ctx = try context.Context.open(path, config());
            defer ctx.close();
            const journal: task.Journal = .{ .ctx = &ctx };
            try std.testing.expectEqual(task.State.running, (try journal.get(id)).state);
            try journal.recoverAfterOwnerExit(id);
            try std.testing.expectEqual(task.State.attention, (try journal.get(id)).state);
            try std.testing.expectEqual(@as(i64, if (started) 1 else 0), try number(&ctx, "SELECT count(*) FROM actions WHERE phase='uncertain';"));
            try std.testing.expectEqual(@as(i64, if (started) 1 else 2), try number(&ctx, "SELECT count(*) FROM actions WHERE phase='abandoned';"));
            try std.testing.expectEqual(@as(i64, if (started) 1 else 0), (try ctx.status()).active_blocks);
            const original = try ctx.retrieve(a, try context.Ref.parse("m1"), 0, 4096);
            defer a.free(original);
            try std.testing.expectEqualStrings(history, original);
            var script: Script = .{ .steps = &.{.{}} };
            defer script.deinit();
            try std.testing.expectError(error.TaskNotPending, agent.run(&ctx, a, io, id, script.provider(), .{}));
            try std.testing.expectEqual(@as(u32, 0), script.seen.load(.acquire));
            try std.testing.expectError(error.SqliteConstraint, ctx.database.exec("UPDATE task_events SET kind='forged';"));
            try std.testing.expectError(error.SqliteConstraint, ctx.database.exec("DELETE FROM actions;"));
            try std.testing.expectError(error.SqliteConstraint, ctx.database.exec("DELETE FROM model_requests;"));
        }
    }
}

test "schema one migration preserves original bytes references generation and identity atomically" {
    const sqlite = @import("db.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pathFor(&tmp);
    defer a.free(path);
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(history, &hash, .{});
    var identity: [32]u8 = undefined;
    {
        var db = try sqlite.Db.openUnconfigured(path);
        defer db.close();
        // Frozen SQL extracted from 8a1b6fc context.zig, before task schema version 2.
        try db.exec(@embedFile("fixtures/context-v1.sql"));
        try db.run("INSERT INTO blobs(hash,body) VALUES(?,?);", &.{ .{ .blob = &hash }, .{ .blob = history } });
        try db.exec("INSERT INTO messages(id,external_id,role,kind,hash,tokens,tool_name,call_id,group_id,pinned) SELECT 1,'old',2,0,hash,100,'','','',0 FROM blobs; UPDATE meta SET value=17 WHERE key='generation'; PRAGMA application_id=0x5a525054; PRAGMA user_version=1;");
        var row = try db.prepare("SELECT identity FROM identity;");
        defer row.deinit();
        try std.testing.expect(try row.step());
        @memcpy(&identity, row.text(0));
    }
    var ctx = try context.Context.open(path, config());
    defer ctx.close();
    try std.testing.expectEqual(@as(i64, 4), try number(&ctx, "PRAGMA user_version;"));
    try std.testing.expectEqual(@as(i64, 17), try ctx.generation());
    var view = try ctx.view(a);
    defer view.deinit();
    try std.testing.expectEqualStrings(&identity, view.session_id);
    try std.testing.expectEqualStrings(history, view.units[0].text);
    try std.testing.expectEqual(try context.Ref.parse("m1"), view.units[0].ref);
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM tasks;"));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM pragma_foreign_key_check;"));
}

test "migration collision rolls back new tables and leaves the old schema version intact" {
    const sqlite = @import("db.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pathFor(&tmp);
    defer a.free(path);
    {
        var db = try sqlite.Db.openUnconfigured(path);
        defer db.close();
        try db.exec(@embedFile("fixtures/context-v1.sql"));
        try db.exec("PRAGMA application_id=0x5a525054; PRAGMA user_version=1; CREATE VIEW actions AS SELECT 1 AS original;");
    }
    try std.testing.expectError(error.Sqlite, context.Context.open(path, config()));
    var db = try sqlite.Db.openUnconfigured(path);
    defer db.close();
    try std.testing.expectEqual(@as(i64, 1), try db.number("PRAGMA user_version;", &.{}));
    try std.testing.expectEqual(@as(i64, 0), try db.number("SELECT count(*) FROM sqlite_master WHERE name IN('tasks','model_requests','task_requirements');", &.{}));
    try std.testing.expectEqual(@as(i64, 1), try db.number("SELECT original FROM actions;", &.{}));
}

test "superseded pure management exchanges stay in the journal without accumulating in prompts" {
    var ctx = try fixture();
    defer ctx.close();
    const id = try create(&ctx, .{});
    const generation = try ctx.generation();
    const fold = try compressArgs(generation);
    defer a.free(fold);
    const expand = try std.fmt.allocPrint(a, "{{\"op\":\"context.expand\",\"generation\":{d},\"ref\":\"b1:v1\",\"deep\":true}}", .{generation + 1});
    defer a.free(expand);
    var first = toolReply("manage-first", &.{.{ .id = "call", .name = "act", .arguments = fold }});
    first.reasoning = "obsolete-management-marker";
    var second = toolReply("manage-second", &.{.{ .id = "call", .name = "act", .arguments = expand }});
    second.reasoning = "latest-management-marker";
    var script: Script = .{ .steps = &.{ .{ .reply = first }, .{ .reply = second }, .{} } };
    defer script.deinit();
    _ = try agent.run(&ctx, a, io, id, script.provider(), .{});
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[1], first.reasoning) != null);
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[2], first.reasoning) == null);
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[2], second.reasoning) != null);
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM model_requests r JOIN blobs b ON b.hash=r.response WHERE instr(CAST(b.body AS TEXT),'obsolete-management-marker')>0;"));
    try std.testing.expectEqual(@as(i64, 2), (try ctx.status()).messages);
}

test "scripted providers cannot bypass typed reply validation or exceed the reserved output usage" {
    for (0..4) |index| {
        var ctx = try fixture();
        defer ctx.close();
        const id = try create(&ctx, .{});
        var record = final;
        switch (index) {
            0 => record.content = &.{0xff},
            1 => record.tools = &.{.{ .id = "call", .name = "inspect", .arguments = "{}" }},
            2 => record.usage = .{ .input_tokens = 1, .output_tokens = 1, .cached_input_tokens = 2 },
            3 => record.usage = .{ .input_tokens = 1, .output_tokens = 4097 },
            else => unreachable,
        }
        var script: Script = .{ .steps = &.{.{ .reply = record }} };
        defer script.deinit();
        const expected = [_]anyerror{ error.InvalidUtf8, error.InconsistentFinishReason, error.InvalidUsage, error.InvalidUsage };
        try std.testing.expectError(expected[index], agent.run(&ctx, a, io, id, script.provider(), .{}));
        try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM actions;"));
    }
}

test "native HTTP provider runs the same bounded durable driver against an owned loopback fixture" {
    const Fixture = @import("provider_http_tests.zig").Fixture;
    var server = try Fixture.init();
    defer server.server.deinit(io);
    server.expected_content = agent.instructions;
    server.chunked = true;
    var ctx = try fixture();
    defer ctx.close();
    const id = try create(&ctx, .{});
    const args = try compressArgs(try ctx.generation());
    defer a.free(args);
    const chunk = try std.json.Stringify.valueAlloc(a, .{
        .id = "http-task-fold",
        .choices = .{.{ .index = 0, .delta = .{ .role = "assistant", .tool_calls = .{.{ .index = 0, .id = "http-action", .type = "function", .function = .{ .name = "act", .arguments = args } }} }, .finish_reason = "tool_calls" }},
    }, .{});
    defer a.free(chunk);
    const first = try std.fmt.allocPrint(a, "data: {s}\n\ndata: [DONE]\n\n", .{chunk});
    defer a.free(first);
    const Sequence = struct {
        fixture: *Fixture,
        second: []const u8,

        fn run(self: *@This()) anyerror!void {
            try self.fixture.run();
            self.fixture.body = self.second;
            try self.fixture.run();
        }
    };
    var sequence: Sequence = .{ .fixture = &server, .second = server.body };
    server.body = first;
    const url = try server.endpoint();
    defer a.free(url);
    var serving = try io.concurrent(Sequence.run, .{&sequence});
    defer _ = serving.cancel(io) catch {};
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var provider: agent.HttpProvider = .{ .client = &client, .endpoint = .{ .url = url, .api_key = "local-fixture", .allow_http_loopback = true } };
    const result = try agent.run(&ctx, a, io, id, provider.provider(), .{});
    try serving.await(io);
    try std.testing.expectEqual(task.State.awaiting_verification, result.state);
    try std.testing.expectEqual(@as(u64, 2), result.requests);
    try std.testing.expectEqual(@as(u64, 5), result.observed_output_tokens);
    try std.testing.expectEqual(@as(u64, 1), result.usage_known_requests);
    try std.testing.expectEqual(@as(i64, 1), (try ctx.status()).active_blocks);
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM actions WHERE phase='succeeded';"));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM blobs WHERE instr(CAST(body AS TEXT),'local-fixture')>0;"));
}

test "older mixed read exchanges and nonempty model findings are retained with trusted system instructions" {
    for ([_]bool{ false, true }) |mixed| {
        var ctx = try fixture();
        defer ctx.close();
        const id = try create(&ctx, .{});
        _ = try ctx.append(a, .{ .external_id = "system-policy", .role = .system, .body = "Trusted system policy fixture." });
        const generation = try ctx.generation();
        const fold = try compressArgs(generation);
        defer a.free(fold);
        const expand = try std.fmt.allocPrint(a, "{{\"op\":\"context.expand\",\"generation\":{d},\"ref\":\"b1:v1\"}}", .{generation + 1});
        defer a.free(expand);
        const calls = [_]stream.ToolCall{
            .{ .id = "first", .name = "act", .arguments = fold },
            .{ .id = "read", .name = "inspect", .arguments = "{\"op\":\"context.retrieve\",\"ref\":\"m1\",\"limit\":128}" },
        };
        var first = toolReply("first-response", calls[0..if (mixed) 2 else 1]);
        first.reasoning = "retained-reasoning-marker";
        if (!mixed) first.content = "Retained model finding, with its evidence.";
        var script: Script = .{ .steps = &.{
            .{ .reply = first },
            .{ .reply = toolReply("second-response", &.{.{ .id = "second", .name = "act", .arguments = expand }}) },
            .{},
        } };
        defer script.deinit();
        _ = try agent.run(&ctx, a, io, id, script.provider(), .{});
        const parsed = try std.json.parseFromSlice(std.json.Value, a, script.payloads.items[2], .{});
        defer parsed.deinit();
        try std.testing.expect(std.mem.indexOf(u8, parsed.value.object.get("messages").?.array.items[0].object.get("content").?.string, "Trusted system policy fixture.") != null);
        try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[2], first.reasoning) != null);
        if (!mixed) try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[2], first.content) != null);
    }
}

test "driver allocation failures release all owned replies and leave no running task or transaction" {
    var allocations: usize = 0;
    {
        var ctx = try fixture();
        defer ctx.close();
        const id = try create(&ctx, .{});
        const args = try compressArgs(try ctx.generation());
        defer a.free(args);
        var script: Script = .{ .steps = &.{ .{ .reply = toolReply("fold", &.{.{ .id = "call", .name = "act", .arguments = args }}) }, .{} } };
        defer script.deinit();
        var measured: std.testing.FailingAllocator = .init(a, .{ .resize_fail_index = 0 });
        _ = try agent.run(&ctx, measured.allocator(), io, id, script.provider(), .{});
        allocations = measured.alloc_index;
        try std.testing.expectEqual(measured.allocated_bytes, measured.freed_bytes);
    }
    var saw_uncertain_effect = false;
    for (0..allocations) |index| {
        var ctx = try fixture();
        defer ctx.close();
        const id = try create(&ctx, .{});
        const args = try compressArgs(try ctx.generation());
        defer a.free(args);
        var script: Script = .{ .steps = &.{ .{ .reply = toolReply("fold", &.{.{ .id = "call", .name = "act", .arguments = args }}) }, .{} } };
        defer script.deinit();
        var failing: std.testing.FailingAllocator = .init(a, .{ .fail_index = index, .resize_fail_index = 0 });
        if (agent.run(&ctx, failing.allocator(), io, id, script.provider(), .{})) |_| {} else |err| {
            try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed or err == error.CommittedResultUnavailable);
        }
        const state = try (task.Journal{ .ctx = &ctx }).get(id);
        try std.testing.expect(state.state != .running);
        try std.testing.expect(!ctx.database.inTransaction());
        if (try number(&ctx, "SELECT count(*) FROM actions WHERE phase='uncertain';") > 0) saw_uncertain_effect = true;
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    try std.testing.expect(saw_uncertain_effect);
}

test "host cancellation during a provider call remains idempotent when the driver acknowledges it" {
    var ctx = try fixture();
    defer ctx.close();
    const id = try create(&ctx, .{});
    var script: Script = .{ .steps = &.{.{ .cancel = .{ .ctx = &ctx, .id = id } }} };
    defer script.deinit();
    try std.testing.expectError(error.Canceled, agent.run(&ctx, a, io, id, script.provider(), .{}));
    const journal: task.Journal = .{ .ctx = &ctx };
    try std.testing.expectEqual(task.State.canceled, (try journal.get(id)).state);
    const generation = try ctx.generation();
    const events = try number(&ctx, "SELECT count(*) FROM task_events;");
    try journal.cancel(id);
    try std.testing.expectEqual(generation, try ctx.generation());
    try std.testing.expectEqual(events, try number(&ctx, "SELECT count(*) FROM task_events;"));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM actions;"));
}

test "length and filtered model finishes are retained as incomplete rather than awaiting verification" {
    for ([_]stream.FinishReason{ .length, .content_filter }) |reason| {
        var ctx = try fixture();
        defer ctx.close();
        const id = try create(&ctx, .{});
        var record = final;
        record.finish_reason = reason;
        var script: Script = .{ .steps = &.{.{ .reply = record }} };
        defer script.deinit();
        try std.testing.expectError(error.IncompleteModelAnswer, agent.run(&ctx, a, io, id, script.provider(), .{}));
        try std.testing.expectEqual(task.State.failed, (try (task.Journal{ .ctx = &ctx }).get(id)).state);
        try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM model_requests WHERE phase='replied';"));
    }
}

test "invalid task limits and generation exhaustion roll back task and context writes" {
    var ctx = try fixture();
    defer ctx.close();
    const before = try ctx.status();
    for ([_]task.Limits{ .{ .requests = 0 }, .{ .requests = 4097 }, .{ .tool_calls = 65_537 }, .{ .management_rounds = 17 }, .{ .wire_bytes = 0 }, .{ .output_tokens = 0 }, .{ .output_per_request = 0 }, .{ .elapsed_ms = 0 }, .{ .elapsed_ms = 3_600_001 } }) |limits| try std.testing.expectError(error.InvalidTaskLimits, create(&ctx, limits));
    try std.testing.expectEqual(before, try ctx.status());
    try std.testing.expectError(error.InvalidTaskSource, (task.Journal{ .ctx = &ctx }).create(1, .{}));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM tasks;"));
    try ctx.database.exec("UPDATE meta SET value=9223372036854775807 WHERE key='generation';");
    try std.testing.expectError(error.GenerationOverflow, create(&ctx, .{}));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM tasks;"));
    try std.testing.expectError(error.GenerationOverflow, ctx.append(a, .{ .external_id = "overflow", .role = .assistant, .body = "Must not commit." }));
    try std.testing.expectEqual(@as(i64, 2), (try ctx.status()).messages);
    try std.testing.expect(!ctx.database.inTransaction());
}

test "an incomplete version two schema fails before being silently recreated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try pathFor(&tmp);
    defer a.free(path);
    {
        var ctx = try context.Context.open(path, config());
        defer ctx.close();
        try ctx.database.exec("DROP TABLE task_events;");
    }
    try std.testing.expectError(error.IncompleteSchema, context.Context.open(path, config()));
}

test "owner-exit recovery invalidates a late context mutation using its earlier generation" {
    var ctx = try fixture();
    defer ctx.close();
    const id = try create(&ctx, .{});
    const journal: task.Journal = .{ .ctx = &ctx };
    try journal.claim(id);
    const generation = try ctx.generation();
    const args = try compressArgs(generation);
    defer a.free(args);
    const request = try journal.reserveRequest(id, generation, "{}", 4096);
    var reply = try cloneReply(a, toolReply("late-action", &.{.{ .id = "call", .name = "act", .arguments = args }}));
    defer reply.deinit();
    try journal.recordReply(a, request, reply);
    try journal.planActions(request, reply.tools, &.{.{ .mutating = true, .management = true }});
    _ = try journal.startAction(request, 0, generation);
    try journal.recoverAfterOwnerExit(id);
    try std.testing.expectError(error.StaleGeneration, @import("context_tools.zig").dispatch(&ctx, a, .{ .name = "act", .arguments = args }));
    try std.testing.expectEqual(@as(i64, 0), (try ctx.status()).active_blocks);
}

test "each task prompt names its registered requirement sources when multiple tasks share context" {
    var ctx = try fixture();
    defer ctx.close();
    const first = try create(&ctx, .{});
    const other_source = try ctx.append(a, .{ .external_id = "unrelated-task", .role = .user, .body = "Separate task: do B rather than this task's nonce work." });
    const second = try (task.Journal{ .ctx = &ctx }).create(other_source, .{});
    var script: Script = .{ .steps = &.{ .{}, .{} } };
    defer script.deinit();
    _ = try agent.run(&ctx, a, io, first, script.provider(), .{});
    _ = try agent.run(&ctx, a, io, second, script.provider(), .{});
    for (script.payloads.items, 0..) |payload, index| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, payload, .{});
        defer parsed.deinit();
        const messages = parsed.value.object.get("messages").?.array.items;
        const guidance = messages[messages.len - 1].object.get("content").?.string;
        try std.testing.expect(std.mem.indexOf(u8, guidance, if (index == 0) "task requirement refs: m2." else "task requirement refs: m3.") != null);
        try std.testing.expect(std.mem.indexOf(u8, guidance, "not automatically additional task goals") != null);
        try std.testing.expect(std.mem.indexOf(u8, messages[1].object.get("content").?.string, "Separate task: do B") != null);
    }
}

test "the native driver reads patches and folds while productive edit evidence survives management projection" {
    const repository = @import("repository.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &path_buffer);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old 🐈\r\n" });
    var ctx = try fixture();
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, path_buffer[0..root_length], &.{.{ .path = "main.zig", .write = true }});
    defer repo.close();
    var base = try repo.read(a, "main.zig", null);
    defer base.deinit(a);
    const id = try create(&ctx, .{ .management_rounds = 1 });
    const generation = try ctx.generation();
    const patch = try std.json.Stringify.valueAlloc(a, .{ .op = "repo.apply", .scope = repo.scope, .generation = generation, .edits = .{.{ .path = "main.zig", .ref = "f1:v1", .replacements = .{.{ .start = 0, .end = 3, .text = "new" }} }} }, .{});
    defer a.free(patch);
    const fold = try compressArgs(generation + 1);
    defer a.free(fold);
    var script: Script = .{ .steps = &.{
        .{ .reply = toolReply("read", &.{.{ .id = "read", .name = "inspect", .arguments = "{\"op\":\"repo.read\",\"path\":\"main.zig\"}" }}) },
        .{ .reply = toolReply("patch", &.{.{ .id = "patch", .name = "patch", .arguments = patch }}) },
        .{ .reply = toolReply("fold", &.{.{ .id = "fold", .name = "act", .arguments = fold }}) },
        .{ .reply = toolReply("status", &.{.{ .id = "status", .name = "inspect", .arguments = "{\"op\":\"context.status\"}" }}) },
        .{},
    } };
    defer script.deinit();
    const state = try agent.run(&ctx, a, io, id, script.provider(), .{ .repository = &repo });
    try std.testing.expectEqual(task.State.awaiting_verification, state.state);
    try std.testing.expectEqual(@as(u64, 1), state.management_rounds);
    const output = try tmp.dir.readFileAlloc(io, "main.zig", a, .limited(4096));
    defer a.free(output);
    try std.testing.expectEqualStrings("new 🐈\r\n", output);
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM actions WHERE name='patch' AND mutating=1 AND management=0 AND phase='succeeded';"));
    try std.testing.expectEqual(@as(i64, 1), try number(&ctx, "SELECT count(*) FROM edit_batches WHERE action_id IS NOT NULL AND state='applied';"));
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[1], "old 🐈") != null);
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[4], "f1:v2") != null);
    try std.testing.expect(std.mem.indexOf(u8, script.payloads.items[4], "retained_displaced_name") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, script.payloads.items[0], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.object.get("tools").?.array.items.len);
}

test "read-only repository schemas omit patch and model input cannot grant write permission" {
    const repository = @import("repository.zig");
    const tools = @import("context_tools.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &path);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old" });
    var ctx = try fixture();
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, path[0..length], &.{.{ .path = "main.zig" }});
    defer repo.close();
    const definitions = try tools.repositoryDefinitions(a, repo.hasWriteAccess());
    defer a.free(definitions);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, definitions, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, definitions, "repo.apply") == null);
    const patch = try std.json.Stringify.valueAlloc(a, .{ .op = "repo.apply", .scope = repo.scope, .generation = try ctx.generation(), .edits = .{.{ .path = "main.zig", .ref = "f1:v1", .replacements = .{.{ .start = 0, .end = 3, .text = "new" }} }} }, .{});
    defer a.free(patch);
    try std.testing.expectError(error.WriteDenied, tools.prepareWithRepository(a, .{ .name = "patch", .arguments = patch }, &repo));
    try std.testing.expectError(error.UnsupportedOperation, tools.prepareWithRepository(a, .{ .name = "patch", .arguments = "{\"op\":\"context.status\"}" }, &repo));
}

test "a malformed later repository call prevents an earlier valid patch in the same burst" {
    const repository = @import("repository.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &root);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "old" });
    var ctx = try fixture();
    defer ctx.close();
    var repo = try repository.Repository.open(&ctx, a, io, root[0..length], &.{.{ .path = "main.zig", .write = true }});
    defer repo.close();
    var base = try repo.read(a, "main.zig", null);
    defer base.deinit(a);
    const id = try create(&ctx, .{});
    const patch = try std.json.Stringify.valueAlloc(a, .{ .op = "repo.apply", .scope = repo.scope, .generation = try ctx.generation(), .edits = .{.{ .path = "main.zig", .ref = "f1:v1", .replacements = .{.{ .start = 0, .end = 3, .text = "new" }} }} }, .{});
    defer a.free(patch);
    var script: Script = .{ .steps = &.{.{ .reply = toolReply("bad-burst", &.{ .{ .id = "valid", .name = "patch", .arguments = patch }, .{ .id = "invalid", .name = "inspect", .arguments = "{\"op\":\"repo.read\",\"path\":\"main.zig\",\"write\":true}" } }) }} };
    defer script.deinit();
    try std.testing.expectError(error.UnknownField, agent.run(&ctx, a, io, id, script.provider(), .{ .repository = &repo }));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM edit_batches;"));
    try std.testing.expectEqual(@as(i64, 0), try number(&ctx, "SELECT count(*) FROM actions;"));
}
