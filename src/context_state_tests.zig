const std = @import("std");
const context = @import("context.zig");
const a = std.testing.allocator;

test "seeded mixed history operations retain every original and recover full order" {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const fixture = arena.allocator();
    var ctx = try context.Context.open(":memory:", .{
        .context_limit = 4 * 1024 * 1024,
        .preserve_recent_messages = 0,
        .preserve_recent_tokens = 0,
        .min_range_bytes = 0,
        .min_summary_bytes = 1,
        .min_benefit_tokens = 0,
    });
    defer ctx.close();
    var rng = std.Random.DefaultPrng.init(0x02e0c0a7);
    const random = rng.random();
    const Original = struct { id: i64, body: []const u8 };
    var originals: std.ArrayList(Original) = .empty;
    var previous_generation: i64 = 0;
    for (0..160) |step| {
        const action = random.uintLessThan(u8, 4);
        if (action == 0 or originals.items.len == 0) {
            const body = try std.fmt.allocPrint(
                fixture,
                "nonce-{d}-{x} retained UTF-8: café 汉字 🦀. Original diagnostic bytes must survive every lossy summary, deep expansion, failed transaction, and later restart. The summary is never a replacement for these exact bytes.",
                .{ step, random.int(u64) },
            );
            const key = try std.fmt.allocPrint(fixture, "event-{d}", .{step});
            const id = try ctx.append(a, .{ .external_id = key, .role = .assistant, .body = body });
            try originals.append(fixture, .{ .id = id, .body = body });
        } else {
            var view = try ctx.view(a);
            defer view.deinit();
            const unit = view.units[random.uintLessThan(usize, view.units.len)];
            if (action == 1) {
                const before = try ctx.status();
                const outcome = ctx.foldBatch(a, view.generation, &.{.{ .start = unit.ref, .end = unit.ref, .summary = "Historical diagnostic." }});
                if (outcome) |ids| a.free(ids) else |err| {
                    try std.testing.expect(err == error.NoCompressionBenefit);
                    try std.testing.expectEqual(before, try ctx.status());
                }
            } else if (action == 2 and unit.ref.kind == .block) {
                try ctx.expand(view.generation, unit.ref, random.boolean());
            } else {
                const compiled = try ctx.compile(a);
                defer a.free(compiled.text);
                try std.testing.expect(compiled.tokens <= ctx.config.context_limit - ctx.config.output_reserve);
            }
        }
        const generation = try ctx.generation();
        try std.testing.expect(generation >= previous_generation);
        previous_generation = generation;
        const original = originals.items[random.uintLessThan(usize, originals.items.len)];
        const offset = random.uintLessThan(usize, original.body.len);
        const page = try ctx.retrieve(a, .{ .kind = .message, .id = original.id }, offset, 37);
        defer a.free(page);
        try std.testing.expectEqualSlices(u8, original.body[offset..@min(offset + 37, original.body.len)], page);
    }
    while (true) {
        var view = try ctx.view(a);
        defer view.deinit();
        var expanded = false;
        for (view.units) |unit| if (unit.ref.kind == .block) {
            try ctx.expand(view.generation, unit.ref, true);
            expanded = true;
            break;
        };
        if (!expanded) break;
    }
    var final = try ctx.view(a);
    defer final.deinit();
    try std.testing.expectEqual(originals.items.len, final.units.len);
    for (originals.items, final.units) |original, unit| {
        try std.testing.expectEqual(original.id, unit.ref.id);
        try std.testing.expectEqualStrings(original.body, unit.text);
    }
    try std.testing.expectError(error.NotFound, ctx.retrieve(a, .{ .kind = .block, .id = 1, .version = 99999 }, 0, 100));
}

test "randomized reference parser never accepts controls signs overflow or invalid kinds" {
    var rng = std.Random.DefaultPrng.init(0x5e6a1d);
    const random = rng.random();
    for (0..1024) |_| {
        var bytes: [32]u8 = undefined;
        random.bytes(&bytes);
        const text = bytes[0..random.uintLessThan(usize, bytes.len + 1)];
        if (context.Ref.parse(text)) |ref| {
            try std.testing.expect(ref.id > 0);
            try std.testing.expect(text[0] == 'm' or text[0] == 'b');
            if (ref.version) |version| try std.testing.expect(version > 0 and ref.kind == .block);
            var rendered: std.Io.Writer.Allocating = .init(a);
            defer rendered.deinit();
            try ref.write(&rendered.writer);
            try std.testing.expectEqual(ref, try context.Ref.parse(rendered.written()));
        } else |err| try std.testing.expect(err == error.InvalidReference);
    }
}
