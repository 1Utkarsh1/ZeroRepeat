const std = @import("std");
const context = @import("context.zig");
const stream = @import("provider_stream.zig");
const sqlite = @import("db.zig");
const Allocator = std.mem.Allocator;

pub const State = enum { pending, running, awaiting_verification, failed, canceled, attention, budget_exhausted };
pub const Effect = struct { mutating: bool, management: bool };

pub const Limits = struct {
    requests: u32 = 16,
    tool_calls: u32 = 64,
    management_rounds: u32 = 8,
    wire_bytes: u32 = 32 * 1024 * 1024,
    output_tokens: u32 = 32_768,
    output_per_request: u32 = 4096,
    elapsed_ms: u32 = 120_000,

    pub fn validate(self: Limits) !void {
        if (self.requests == 0 or self.requests > 4096 or self.tool_calls > 65_536 or
            self.management_rounds > self.requests or self.wire_bytes == 0 or
            self.output_tokens == 0 or self.output_per_request == 0 or self.elapsed_ms == 0 or
            self.elapsed_ms > 3_600_000) return error.InvalidTaskLimits;
    }
};

pub const Snapshot = struct {
    id: i64,
    state: State,
    limits: Limits,
    elapsed_ms: u64,
    requests: u64,
    tool_calls: u64,
    management_rounds: u64,
    wire_bytes: u64,
    /// Unknown requests consume their reserved output ceiling, not fabricated usage.
    output_charged: u64,
    usage_known_requests: u64,
    observed_input_tokens: u64,
    observed_output_tokens: u64,
    cached_usage_known_requests: u64,
    observed_cached_input_tokens: u64,
    reasoning_usage_known_requests: u64,
    observed_reasoning_tokens: u64,
};

/// Exact provider-boundary data; original reasoning and call IDs remain auditable.
pub const ReplyRecord = struct {
    id: []const u8,
    content: []const u8,
    reasoning: []const u8,
    tools: []const stream.ToolCall,
    finish_reason: stream.FinishReason,
    usage: ?stream.Usage,

    pub fn from(reply: stream.Reply) ReplyRecord {
        return .{ .id = reply.id, .content = reply.content, .reasoning = reply.reasoning, .tools = reply.tools, .finish_reason = reply.finish_reason, .usage = reply.usage };
    }
};

pub const Journal = struct {
    ctx: *context.Context,

    fn db(self: Journal) *sqlite.Db {
        return &self.ctx.database;
    }

    fn event(self: Journal, id: i64, kind: []const u8, request: ?i64, action: ?i64) !void {
        try self.db().run("INSERT INTO task_events(task_id,kind,request_id,action_id) VALUES(?,?,?,?);", &.{
            .{ .int = id }, .{ .text = kind }, if (request) |value| .{ .int = value } else .null, if (action) |value| .{ .int = value } else .null,
        });
    }

    pub fn get(self: Journal, id: i64) !Snapshot {
        var row = try self.db().statement(
            "SELECT state,max_requests,max_tool_calls,max_management_rounds,max_wire_bytes,max_output_tokens,output_per_request,max_elapsed_ms,elapsed_ms," ++
                "(SELECT count(*) FROM model_requests WHERE task_id=t.id)," ++
                "(SELECT count(*) FROM actions a JOIN model_requests r ON r.id=a.request_id WHERE r.task_id=t.id)," ++
                "(SELECT coalesce(sum(management),0) FROM model_requests WHERE task_id=t.id)," ++
                "(SELECT coalesce(sum(length(b.body)),0) FROM model_requests r JOIN blobs b ON b.hash=r.payload WHERE r.task_id=t.id)," ++
                "(SELECT coalesce(sum(coalesce(output_tokens,output_reserved)),0) FROM model_requests WHERE task_id=t.id)," ++
                "(SELECT count(input_tokens) FROM model_requests WHERE task_id=t.id)," ++
                "(SELECT coalesce(sum(input_tokens),0) FROM model_requests WHERE task_id=t.id)," ++
                "(SELECT coalesce(sum(output_tokens),0) FROM model_requests WHERE task_id=t.id)," ++
                "(SELECT count(cached_input_tokens) FROM model_requests WHERE task_id=t.id)," ++
                "(SELECT coalesce(sum(cached_input_tokens),0) FROM model_requests WHERE task_id=t.id)," ++
                "(SELECT count(reasoning_tokens) FROM model_requests WHERE task_id=t.id)," ++
                "(SELECT coalesce(sum(reasoning_tokens),0) FROM model_requests WHERE task_id=t.id) FROM tasks t WHERE id=?;",
            &.{.{ .int = id }},
        );
        defer row.deinit();
        if (!try row.step()) return error.NotFound;
        return .{
            .id = id,
            .state = std.meta.stringToEnum(State, row.text(0)) orelse return error.CorruptTask,
            .limits = .{ .requests = @intCast(row.int(1)), .tool_calls = @intCast(row.int(2)), .management_rounds = @intCast(row.int(3)), .wire_bytes = @intCast(row.int(4)), .output_tokens = @intCast(row.int(5)), .output_per_request = @intCast(row.int(6)), .elapsed_ms = @intCast(row.int(7)) },
            .elapsed_ms = @intCast(row.int(8)),
            .requests = @intCast(row.int(9)),
            .tool_calls = @intCast(row.int(10)),
            .management_rounds = @intCast(row.int(11)),
            .wire_bytes = @intCast(row.int(12)),
            .output_charged = @intCast(row.int(13)),
            .usage_known_requests = @intCast(row.int(14)),
            .observed_input_tokens = @intCast(row.int(15)),
            .observed_output_tokens = @intCast(row.int(16)),
            .cached_usage_known_requests = @intCast(row.int(17)),
            .observed_cached_input_tokens = @intCast(row.int(18)),
            .reasoning_usage_known_requests = @intCast(row.int(19)),
            .observed_reasoning_tokens = @intCast(row.int(20)),
        };
    }

    fn requireRunning(self: Journal, id: i64) !void {
        const state = (try self.get(id)).state;
        if (state == .canceled) return error.Canceled;
        if (state != .running) return error.TaskNotRunning;
    }

    fn requirement(self: Journal, id: i64, source: i64) !void {
        if (try self.db().number("SELECT count(*) FROM messages m WHERE id=? AND role=1 AND kind=0 AND NOT EXISTS(SELECT 1 FROM block_members bm JOIN blocks b ON b.id=bm.block_id WHERE b.active=1 AND bm.message_id=m.id);", &.{.{ .int = source }}) != 1)
            return error.InvalidTaskSource;
        try self.db().run("INSERT OR IGNORE INTO task_requirements VALUES(?,?);", &.{ .{ .int = id }, .{ .int = source } });
        if (try self.db().number("SELECT changes();", &.{}) != 0) {
            try self.ctx.advanceGeneration();
            try self.event(id, "requirement", null, null);
        }
    }

    pub fn create(self: Journal, source: i64, limits: Limits) !i64 {
        try limits.validate();
        try self.db().exec("BEGIN IMMEDIATE;");
        errdefer self.db().exec("ROLLBACK;") catch {};
        try self.db().run("INSERT INTO tasks(state,max_requests,max_tool_calls,max_management_rounds,max_wire_bytes,max_output_tokens,output_per_request,max_elapsed_ms) VALUES('pending',?,?,?,?,?,?,?);", &.{
            .{ .int = limits.requests }, .{ .int = limits.tool_calls }, .{ .int = limits.management_rounds }, .{ .int = limits.wire_bytes }, .{ .int = limits.output_tokens }, .{ .int = limits.output_per_request }, .{ .int = limits.elapsed_ms },
        });
        const id = try self.db().number("SELECT last_insert_rowid();", &.{});
        try self.requirement(id, source);
        try self.event(id, "created", null, null);
        try self.db().exec("COMMIT;");
        return id;
    }

    /// Trusted host entrypoint; model tools cannot manufacture user obligations.
    pub fn addRequirement(self: Journal, id: i64, source: i64) !void {
        try self.db().exec("BEGIN IMMEDIATE;");
        errdefer self.db().exec("ROLLBACK;") catch {};
        const state = (try self.get(id)).state;
        if (state != .pending and state != .running and state != .awaiting_verification) return error.TaskNotEditable;
        try self.requirement(id, source);
        try self.db().exec("COMMIT;");
    }

    pub fn claim(self: Journal, id: i64) !void {
        try self.db().exec("BEGIN IMMEDIATE;");
        errdefer self.db().exec("ROLLBACK;") catch {};
        if ((try self.get(id)).state != .pending) return error.TaskNotPending;
        try self.db().run("UPDATE tasks SET state='running' WHERE id=?;", &.{.{ .int = id }});
        try self.event(id, "running", null, null);
        try self.db().exec("COMMIT;");
    }

    pub fn reserveRequest(self: Journal, id: i64, generation: i64, payload: []const u8, output: u32) !i64 {
        try self.db().exec("BEGIN IMMEDIATE;");
        errdefer self.db().exec("ROLLBACK;") catch {};
        try self.requireRunning(id);
        const state = try self.get(id);
        if (state.requests >= state.limits.requests or payload.len > state.limits.wire_bytes -| state.wire_bytes or
            output == 0 or output > state.limits.output_per_request or output > state.limits.output_tokens -| state.output_charged) return error.TaskBudgetExceeded;
        if (try self.ctx.generation() != generation) return error.StaleGeneration;
        if (try self.db().number("SELECT count(*) FROM model_requests WHERE task_id=? AND phase='started';", &.{.{ .int = id }}) != 0) return error.RequestAlreadyRunning;
        if (try self.db().number("SELECT count(*) FROM actions a JOIN model_requests r ON r.id=a.request_id WHERE r.task_id=? AND a.phase IN('planned','started','uncertain');", &.{.{ .int = id }}) != 0) return error.UnfinishedActions;
        const hash = try self.ctx.putBlob(payload);
        try self.db().run("INSERT INTO model_requests(task_id,generation,payload,output_reserved,phase) VALUES(?,?,?,?,'started');", &.{ .{ .int = id }, .{ .int = generation }, .{ .blob = &hash }, .{ .int = output } });
        const request = try self.db().number("SELECT last_insert_rowid();", &.{});
        try self.event(id, "request_started", request, null);
        try self.db().exec("COMMIT;");
        return request;
    }

    fn requestTask(self: Journal, request: i64, phase: []const u8) !i64 {
        const id = try self.db().number("SELECT task_id FROM model_requests WHERE id=? AND phase=?;", &.{ .{ .int = request }, .{ .text = phase } });
        try self.requireRunning(id);
        return id;
    }

    pub fn recordReply(self: Journal, allocator: Allocator, request: i64, reply: stream.Reply) !void {
        try reply.validate(allocator, .{});
        const bytes = try std.json.Stringify.valueAlloc(allocator, ReplyRecord.from(reply), .{});
        defer allocator.free(bytes);
        try self.db().exec("BEGIN IMMEDIATE;");
        errdefer self.db().exec("ROLLBACK;") catch {};
        const id = try self.requestTask(request, "started");
        const reserved = try self.db().number("SELECT output_reserved FROM model_requests WHERE id=?;", &.{.{ .int = request }});
        if (reply.usage) |usage| if (usage.output_tokens > reserved or usage.input_tokens > std.math.maxInt(i64) - (try self.get(id)).observed_input_tokens) return error.InvalidUsage;
        const hash = try self.ctx.putBlob(bytes);
        const usage = reply.usage;
        try self.db().run("UPDATE model_requests SET phase='replied',response=?,response_id=?,input_tokens=?,output_tokens=?,cached_input_tokens=?,reasoning_tokens=? WHERE id=?;", &.{
            .{ .blob = &hash },                                                                            .{ .text = reply.id },
            if (usage) |u| .{ .int = @intCast(u.input_tokens) } else .null,                                if (usage) |u| .{ .int = @intCast(u.output_tokens) } else .null,
            if (usage) |u| (if (u.cached_input_tokens) |n| .{ .int = @intCast(n) } else .null) else .null, if (usage) |u| (if (u.reasoning_tokens) |n| .{ .int = @intCast(n) } else .null) else .null,
            .{ .int = request },
        });
        try self.event(id, "request_replied", request, null);
        try self.db().exec("COMMIT;");
    }

    pub fn reject(self: Journal, request: i64, diagnostic: []const u8) !void {
        try self.db().exec("BEGIN IMMEDIATE;");
        errdefer self.db().exec("ROLLBACK;") catch {};
        const id = try self.requestTask(request, "started");
        try self.db().run("UPDATE model_requests SET phase='rejected',diagnostic=? WHERE id=?;", &.{ .{ .text = diagnostic }, .{ .int = request } });
        try self.event(id, "request_rejected", request, null);
        try self.db().exec("COMMIT;");
    }

    /// All plans are validated before this reservation or any action start.
    pub fn planActions(self: Journal, request: i64, calls: []const stream.ToolCall, effects: []const Effect) !void {
        if (calls.len == 0 or calls.len != effects.len) return error.InvalidActionPlan;
        try self.db().exec("BEGIN IMMEDIATE;");
        errdefer self.db().exec("ROLLBACK;") catch {};
        const id = try self.requestTask(request, "replied");
        const state = try self.get(id);
        var management = false;
        for (effects) |effect| {
            if (effect.management and !effect.mutating) return error.InvalidActionPlan;
            management = management or effect.management;
        }
        if (calls.len > state.limits.tool_calls -| state.tool_calls or
            (management and state.management_rounds >= state.limits.management_rounds)) return error.TaskBudgetExceeded;
        if (try self.db().number("SELECT count(*) FROM actions WHERE request_id=?;", &.{.{ .int = request }}) != 0) return error.ActionsAlreadyPlanned;
        for (calls, effects, 0..) |call, effect, position| {
            const hash = try self.ctx.putBlob(call.arguments);
            try self.db().run("INSERT INTO actions(request_id,position,provider_id,name,arguments,mutating,management,phase) VALUES(?,?,?,?,?,?,?,'planned');", &.{
                .{ .int = request }, .{ .int = @intCast(position) }, .{ .text = call.id }, .{ .text = call.name }, .{ .blob = &hash }, .{ .int = @intFromBool(effect.mutating) }, .{ .int = @intFromBool(effect.management) },
            });
        }
        try self.db().run("UPDATE model_requests SET management=? WHERE id=?;", &.{ .{ .int = @intFromBool(management) }, .{ .int = request } });
        try self.event(id, "actions_planned", request, null);
        try self.db().exec("COMMIT;");
    }

    pub fn startAction(self: Journal, request: i64, position: usize, generation: i64) !i64 {
        try self.db().exec("BEGIN IMMEDIATE;");
        errdefer self.db().exec("ROLLBACK;") catch {};
        const id = try self.requestTask(request, "replied");
        if (try self.ctx.generation() != generation) return error.StaleGeneration;
        if (try self.db().number("SELECT count(*) FROM actions WHERE request_id=? AND (phase='started' OR (position<? AND phase NOT IN('succeeded','failed')));", &.{ .{ .int = request }, .{ .int = @intCast(position) } }) != 0) return error.UnfinishedActions;
        const action = try self.db().number("SELECT id FROM actions WHERE request_id=? AND position=? AND phase='planned';", &.{ .{ .int = request }, .{ .int = @intCast(position) } });
        try self.db().run("UPDATE actions SET phase='started' WHERE id=?;", &.{.{ .int = action }});
        try self.event(id, "action_started", request, action);
        try self.db().exec("COMMIT;");
        return action;
    }

    pub fn finishAction(self: Journal, action: i64, result: []const u8, diagnostic: []const u8) !bool {
        try self.db().exec("BEGIN IMMEDIATE;");
        errdefer self.db().exec("ROLLBACK;") catch {};
        const request = try self.db().number("SELECT request_id FROM actions WHERE id=? AND phase='started';", &.{.{ .int = action }});
        const id = try self.requestTask(request, "replied");
        const hash = try self.ctx.putBlob(result);
        try self.db().run("UPDATE actions SET phase=?,result=?,diagnostic=? WHERE id=?;", &.{ .{ .text = if (diagnostic.len == 0) "succeeded" else "failed" }, .{ .blob = &hash }, .{ .text = diagnostic }, .{ .int = action } });
        const repeated = diagnostic.len > 0 and try self.db().number("SELECT count(*) FROM actions a JOIN model_requests r ON r.id=a.request_id WHERE r.task_id=? AND a.phase='failed' AND (a.name,a.arguments,a.diagnostic)=(SELECT name,arguments,diagnostic FROM actions WHERE id=?);", &.{ .{ .int = id }, .{ .int = action } }) >= 2;
        try self.event(id, if (diagnostic.len == 0) "action_succeeded" else "action_failed", request, action);
        try self.db().exec("COMMIT;");
        return repeated;
    }

    /// Never clears uncertainty or replays work. Recovery requires the previous owner to be gone.
    pub fn recoverAfterOwnerExit(self: Journal, id: i64) !void {
        if ((try self.get(id)).state != .running) return error.TaskNotRunning;
        try self.finish(id, .attention, "OwnerExited", 0);
    }

    pub fn cancel(self: Journal, id: i64) !void {
        try self.finish(id, .canceled, "Canceled", 0);
    }

    pub fn finish(self: Journal, id: i64, requested: State, diagnostic: []const u8, elapsed_ms: u64) !void {
        if (requested == .pending or requested == .running or diagnostic.len > 128 or elapsed_ms > std.math.maxInt(i64)) return error.InvalidTaskTransition;
        try self.db().exec("BEGIN IMMEDIATE;");
        errdefer self.db().exec("ROLLBACK;") catch {};
        const current = (try self.get(id)).state;
        if (current == .canceled and elapsed_ms == 0) {
            try self.db().exec("COMMIT;");
            return;
        }
        if (current != .running and current != .canceled and requested != .canceled) return error.InvalidTaskTransition;
        if (requested == .canceled and current != .canceled and current != .running and current != .pending and current != .awaiting_verification and current != .attention and current != .failed and current != .budget_exhausted) return error.InvalidTaskTransition;
        const uncertain = try self.db().number("SELECT (SELECT count(*) FROM model_requests WHERE task_id=? AND phase='started')+(SELECT count(*) FROM actions a JOIN model_requests r ON r.id=a.request_id WHERE r.task_id=? AND a.phase='started');", &.{ .{ .int = id }, .{ .int = id } }) != 0;
        if (requested == .awaiting_verification and (uncertain or try self.db().number("SELECT count(*) FROM actions a JOIN model_requests r ON r.id=a.request_id WHERE r.task_id=? AND a.phase='planned';", &.{.{ .int = id }}) != 0)) return error.UnfinishedActions;
        try self.db().run("UPDATE model_requests SET phase='uncertain',diagnostic=? WHERE task_id=? AND phase='started';", &.{ .{ .text = diagnostic }, .{ .int = id } });
        try self.db().run("UPDATE actions SET phase=CASE WHEN phase='started' THEN 'uncertain' ELSE 'abandoned' END,diagnostic=? WHERE request_id IN(SELECT id FROM model_requests WHERE task_id=?) AND phase IN('planned','started');", &.{ .{ .text = diagnostic }, .{ .int = id } });
        const state: State = if (current == .canceled) .canceled else if (uncertain and requested != .canceled) .attention else requested;
        try self.db().run("UPDATE tasks SET state=?,reason=?,elapsed_ms=elapsed_ms+? WHERE id=?;", &.{ .{ .text = @tagName(state) }, .{ .text = diagnostic }, .{ .int = @intCast(elapsed_ms) }, .{ .int = id } });
        if ((state == .canceled or state == .attention) and current != state) try self.ctx.advanceGeneration();
        try self.event(id, @tagName(state), null, null);
        try self.db().exec("COMMIT;");
    }
};
