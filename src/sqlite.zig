const std = @import("std");
const c = @import("c");
const Sqlite = @This();

raw: *c.sqlite3,

pub fn open(file_name: [:0]const u8) SqliteError!Sqlite {
    var raw_nullable: ?*c.sqlite3 = undefined;
    _ = try check(c.sqlite3_open(file_name, &raw_nullable));
    return Sqlite{ .raw = raw_nullable.? };
}

// zig zen: resource deallocation must succeed
// the caller is in charge of blocking until DB is closeable
// here we just panic
pub fn close(self: *Sqlite) void {
    _ = check(self.raw.sqlite3_close()) catch {
        @panic("DB was busy, could not cleanly close");
    };
}

pub fn statement(self: *Sqlite, sql: [:0]const u8) UnpreparedStatement {
    return .{ .db = self, .sql = sql };
}

const UnpreparedStatement = struct {
    db: *Sqlite,
    sql: [:0]const u8,

    pub fn prepare(
        self: *UnpreparedStatement,
    ) SqliteError!?Statement {
        if (self.sql.len == 0) return null;

        var stmt_nullable: ?*c.sqlite3_stmt = undefined;
        var rest: ?*const u8 = undefined;
        _ = try check(self.db.raw.sqlite3_prepare_v2(
            self.sql,
            @intCast(self.sql.len + 1),
            &stmt_nullable,
            &rest,
        ));

        const offset = rest.? - self.sql.ptr;
        self.sql = self.sql[offset..];
        if (stmt_nullable) |stmt| {
            return Statement{ .raw = stmt };
        }
        return null;
    }
};

const Statement = struct {
    raw: *c.sqlite3_stmt,

    // zig zen: resource deallocation must succeed
    //
    // The sqlite3_finalize() function is called to delete
    // a prepared statement. If the most recent evaluation of the
    // statement encountered no errors or if the statement has never been
    // evaluated, then sqlite3_finalize() returns SQLITE_OK. If the most
    // recent evaluation of statement S failed, then sqlite3_finalize(S)
    // returns the appropriate error code or extended error code.
    //
    // The returned error code mirrors that of the last evaluation,
    // not of finalize itself
    pub fn finalize(self: *Statement) void {
        _ = self.raw.sqlite3_finalize();
    }

    pub fn step(self: *Statement) SqliteError!bool {
        const res = try check(self.raw.sqlite3_step());
        return res == .SqliteRow;
    }

    pub fn parse(
        self: *Statement,
        comptime Row: type,
        failed_column: ?*usize,
    ) !Row {
        const field_names = @typeInfo(Row).@"struct".field_names;
        const field_types = @typeInfo(Row).@"struct".field_types;

        var result: Row = undefined;
        var i: usize = 0;
        inline for (field_names, field_types) |field_name, field_type| {
            const col = self.column(i);

            std.debug.assert(std.mem.eql(
                u8,
                col.name(),
                field_name,
            ));

            comptime var is_optional = false;
            const resolved_type = switch (@typeInfo(field_type)) {
                .optional => |info| blk: {
                    is_optional = true;
                    break :blk info.child;
                },
                else => field_type,
            };

            const value = switch (resolved_type) {
                // TODO: blob vs text
                // probably we will do blob as []const u8
                // I mean kind of implicit but whatever
                // Also maybe don't even expose blob here,
                // looks like there is a fopen/fclose style interface
                i32 => col.int(),
                i64 => col.int64(),
                f64 => col.double(),
                [:0]const u8 => col.text(),
                else => @panic("not implemented"),
            } catch |err| {
                if (failed_column) |ptr| {
                    ptr.* = i;
                }
                return err;
            };

            if (is_optional) {
                @field(result, field_name) = value;
            } else {
                @field(result, field_name) = value orelse {
                    if (failed_column) |ptr| {
                        ptr.* = i;
                    }
                    return error.TypeError;
                };
            }
            i += 1;
        }

        std.debug.assert(self.column_count() == i);

        return result;
    }

    pub fn column(self: *Statement, index: usize) Column {
        return .{ .raw_stmt = self.raw, .index = @intCast(index) };
    }

    pub fn column_count(self: *Statement) usize {
        return @intCast(self.raw.sqlite3_column_count());
    }
};

const Column = struct {
    // should we store Statement or directly the C opaque ptr?
    // law of demeter: self.raw_stmt vs self.statement.raw
    // let the Column own it if it's going to use it,
    // otherwise expose appropriate indirection points in Statement
    raw_stmt: *c.sqlite3_stmt,
    index: c_int,

    pub fn raw_name(self: Column) [*:0]const u8 {
        return self.raw_stmt.sqlite3_column_name(self.index);
    }

    pub fn name(self: Column) [:0]const u8 {
        const col_name = self.raw_name();
        const len = std.mem.len(col_name);
        return col_name[0..len :0];
    }

    const ColumnType = enum(u8) {
        // hard code vs use the c.X macro?
        SqliteInteger = 1,
        SqliteFloat = 2,
        SqliteText = 3,
        SqliteBlob = 4,
        SqliteNull = 5,
    };

    pub fn @"type"(self: Column) ColumnType {
        return @fromBackingInt(@intCast(
            self.raw_stmt.sqlite3_column_type(self.index),
        ));
    }

    pub fn int(self: Column) !?i32 {
        return switch (self.@"type"()) {
            .SqliteInteger => self.raw_stmt.sqlite3_column_int(self.index),
            .SqliteNull => null,
            else => error.TypeError,
        };
    }

    pub fn int64(self: Column) !?i64 {
        return switch (self.@"type"()) {
            .SqliteInteger => self.raw_stmt.sqlite3_column_int64(self.index),
            .SqliteNull => null,
            else => error.TypeError,
        };
    }

    pub fn double(self: Column) !?f64 {
        return switch (self.@"type"()) {
            .SqliteFloat => self.raw_stmt.sqlite3_column_double(self.index),
            .SqliteNull => null,
            else => error.TypeError,
        };
    }

    pub fn raw_text(self: Column) !?[*:0]const u8 {
        return switch (self.@"type"()) {
            .SqliteText => self.raw_stmt.sqlite3_column_text(self.index),
            .SqliteNull => null,
            else => error.TypeError,
        };
    }

    pub fn text(self: Column) !?[:0]const u8 {
        if (try self.raw_text()) |col_text| {
            const size = self.raw_stmt.sqlite3_column_bytes(self.index);
            return col_text[0..@intCast(size) :0];
        }
        return null;
    }
};

const SqliteError = error{
    // Generic error
    SqliteError,
    // Internal logic error in SQLite
    SqliteInternal,
    // Access permission denied
    SqlitePerm,
    // Callback routine requested an abort
    SqliteAbort,
    // The database file is locked
    SqliteBusy,
    // A table in the database is locked
    SqliteLocked,
    // A malloc() failed
    SqliteNoMem,
    // Attempt to write a readonly database
    SqliteReadOnly,
    // Operation terminated by sqlite3_interrupt(
    SqliteInterrupt,
    // Some kind of disk I/O error occurred
    SqliteIoErr,
    // The database disk image is malformed
    SqliteCorrupt,
    // Unknown opcode in sqlite3_file_control()
    SqliteNotFound,
    // Insertion failed because database is full
    SqliteFull,
    // Unable to open the database file
    SqliteCantOpen,
    // Database lock protocol error
    SqliteProtocol,
    // No content
    SqliteEmpty,
    // The database schema changed
    SqliteSchema,
    // String or BLOB exceeds size limit
    SqliteTooBig,
    // Abort due to constraint violation
    SqliteConstraint,
    // Data type mismatch
    SqliteMismatch,
    // Library used incorrectly
    SqliteMisuse,
    // Uses OS features not supported on host
    SqliteNoLfs,
    // Authorization denied
    SqliteAuth,
    // Not used
    SqliteFormat,
    // 2nd parameter to sqlite3_bind out of range
    SqliteRange,
    // File opened that is not a database file
    SqliteNotADb,
    // Notifications from sqlite3_log()
    SqliteNotice,
    // Warnings from sqlite3_log()
    SqliteWarning,
};

// Here, we do use c.X macro because non-contiguous magic numbers
const SqliteSuccess = enum(u8) {
    SqliteOk = c.SQLITE_OK,
    SqliteRow = c.SQLITE_ROW,
    SqliteDone = c.SQLITE_DONE,
};

fn check(status_code: c_int) SqliteError!SqliteSuccess {
    const base_code: u8 = @intCast(status_code & 0xff);
    return switch (base_code) {
        // non-error status codes
        c.SQLITE_OK,
        c.SQLITE_ROW,
        c.SQLITE_DONE,
        => @fromBackingInt(base_code),
        c.SQLITE_ERROR => error.SqliteError,
        c.SQLITE_INTERNAL => error.SqliteInternal,
        c.SQLITE_PERM => error.SqlitePerm,
        c.SQLITE_ABORT => error.SqliteAbort,
        c.SQLITE_BUSY => error.SqliteBusy,
        c.SQLITE_LOCKED => error.SqliteLocked,
        c.SQLITE_NOMEM => error.SqliteNoMem,
        c.SQLITE_READONLY => error.SqliteReadOnly,
        c.SQLITE_INTERRUPT => error.SqliteInterrupt,
        c.SQLITE_IOERR => error.SqliteIoErr,
        c.SQLITE_CORRUPT => error.SqliteCorrupt,
        c.SQLITE_NOTFOUND => error.SqliteNotFound,
        c.SQLITE_FULL => error.SqliteFull,
        c.SQLITE_CANTOPEN => error.SqliteCantOpen,
        c.SQLITE_PROTOCOL => error.SqliteProtocol,
        c.SQLITE_EMPTY => error.SqliteEmpty,
        c.SQLITE_SCHEMA => error.SqliteSchema,
        c.SQLITE_TOOBIG => error.SqliteTooBig,
        c.SQLITE_CONSTRAINT => error.SqliteConstraint,
        c.SQLITE_MISMATCH => error.SqliteMismatch,
        c.SQLITE_MISUSE => error.SqliteMisuse,
        c.SQLITE_NOLFS => error.SqliteNoLfs,
        c.SQLITE_AUTH => error.SqliteAuth,
        c.SQLITE_FORMAT => error.SqliteFormat,
        c.SQLITE_RANGE => error.SqliteRange,
        c.SQLITE_NOTADB => error.SqliteNotADb,
        c.SQLITE_NOTICE => error.SqliteNotice,
        c.SQLITE_WARNING => error.SqliteWarning,
        else => unreachable,
    };
}
