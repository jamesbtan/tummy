const std = @import("std");
const Sqlite = @import("sqlite");

const Result = struct {
    a: i32,
    b: i64,
    c: f64,
    d: [:0]const u8,
    n_a: ?i32,
    n_b: ?i64,
    n_c: ?f64,
    n_d: ?[:0]const u8,
};

pub fn main() !void {
    var s = try Sqlite.open(":memory:");
    defer s.close();

    {
        const sql: [:0]const u8 =
            \\CREATE TABLE IF NOT EXISTS test(a integer, b integer);
            \\SELECT 1 as a, 2 as b, 3.4 as c, 'capybara' as d,
            \\null as n_a, null as n_b, null as n_c, null as n_d;
        ;
        var stmt = s.statement(sql);
        while (true) {
            var p = try stmt.prepare() orelse break;
            defer p.finalize();
            std.debug.print("{s}\nrest: {s}\n\n", .{ sql, stmt.sql });

            var i: u32 = 0;
            while (try p.step()) : (i += 1) {
                const result = try p.parse(Result, null);
                std.debug.print("{}: {} {} {} {s} {} {?} {?} {?} {?s}\n", .{
                    i,
                    result.a,
                    result.b,
                    result.c,
                    result.d,
                    result.d.len,
                    result.n_a,
                    result.n_b,
                    result.n_c,
                    result.n_d,
                });
            }
        }
    }
}
