const std = @import("std");
pub const zluajit = @import("zluajit");
pub const xev = @import("xev");

const AIO = @import("./AIO.zig");
const Task = @import("./Task.zig");

export fn luaopen_aio(lua: ?*zluajit.c.lua_State) callconv(.c) c_int {
    const L = zluajit.State.initFromCPointer(lua.?);

    const mod = L.newTableRef();
    if (L.newMetaTableWithName("aio")) {
        AIO.init(L) catch unreachable;
        const mt = L.toAnyType(-1, zluajit.TableRef).?;
        mt.set("__gc", AIO.deinit);
        mt.set("__metatable", false);
    }
    L.setMetaTable(mod.ref.idx);

    mod.set("poll", poll);
    mod.set("sleep", sleep);
    mod.set("open", open);
    mod.set("close", close);
    mod.set("read", read);
    mod.set("pread", pread);

    return 1;
}

/// Poll polls event loop until one task complete or fail.
fn poll(mode: ?xev.RunMode) !void {
    try AIO.poll(mode orelse xev.RunMode.once);
}

/// Schedules a sleep task on the event loop.
fn sleep(L: zluajit.State, secs: zluajit.Number) !c_int {
    const ms: u64 = @intFromFloat(secs * 1000);
    const timer = try xev.Timer.init();

    const sleep_task = try Task.init(L, .{});
    errdefer sleep_task.deinit();

    // Update loop cached time as sleep duration is relative to it. If we don't
    // do this, sleep may be shorter than duration provided by caller.
    AIO.loop.update_now();

    timer.run(
        &AIO.loop,
        &sleep_task.completion,
        ms,
        Task,
        sleep_task,
        struct {
            pub fn callback(
                t: ?*Task,
                _: *xev.Loop,
                _: *xev.Completion,
                r: anyerror!void,
            ) xev.CallbackAction {
                const task = t.?;
                defer task.deinit();

                r catch |err| {
                    task.L.pushBool(false);
                    task.L.pushString(@errorName(err));
                    task.failed();
                    return .disarm;
                };

                task.L.pushBool(true);
                task.completed();
                return .disarm;
            }
        }.callback,
    );

    return sleep_task.started();
}

/// FD is a Lua userdata wrapping a std.posix.fd_t.
const FD = struct {
    const zluajitTName = "aio.FD";

    fd: std.posix.fd_t,
};

/// Opens file at fpath and returns a FD.
fn open(
    L: zluajit.State,
    fpath: []const u8,
    opts: zluajit.TableRef,
) !c_int {
    const f = L.newUserData(FD);
    if (L.newMetaTableRef(FD)) |mt| {
        mt.set("__gc", struct {
            fn close(file: *FD) void {
                std.posix.close(file.fd);
            }
        }.close);
    }
    L.setMetaTable(-2);

    var o: std.posix.O = .{};
    if (opts.pop("read", bool) == true) {
        o.ACCMODE = .RDONLY;
    }
    if (opts.pop("write", bool) == true) {
        if (o.ACCMODE == .RDONLY) o.ACCMODE = .RDWR else o.ACCMODE = .WRONLY;
    }
    if (opts.pop("truncate", bool) == true) {
        o.TRUNC = true;
    }
    if (opts.pop("append", bool) == true) {
        o.APPEND = true;
    }
    if (opts.pop("create", bool) == true) {
        o.CREAT = true;
    }
    if (opts.pop("create_new", bool) == true) {
        o.CREAT = true;
        o.EXCL = true;
    }

    const perm: std.posix.mode_t = 0o0666;

    f.fd = try std.posix.open(fpath, o, perm);

    return 1;
}

/// Reads from FD into buffer.
fn read(
    L: zluajit.State,
    f: *FD,
    buf: [*c]u8,
    len: usize,
) !c_int {
    const read_task = try Task.init(L, .{
        .op = .{ .read = .{
            .fd = f.fd,
            .buffer = .{ .slice = buf[0..len] },
        } },
        .callback = struct {
            pub fn callback(
                t: ?*anyopaque,
                _: *xev.Loop,
                _: *xev.Completion,
                result: xev.Result,
            ) xev.CallbackAction {
                const task: *Task = @ptrCast(@alignCast(t.?));
                defer task.deinit();

                const r = result.read catch |err| {
                    task.L.pushBool(false);
                    task.L.pushString(@errorName(err));
                    task.failed();
                    return .disarm;
                };

                task.L.pushBool(true);
                task.L.pushInteger(@intCast(r));
                task.completed();
                return .disarm;
            }
        }.callback,
    });
    errdefer read_task.deinit();

    AIO.loop.add(&read_task.completion);

    return read_task.started();
}

/// Reads from FD at specified offset into buffer.
fn pread(
    L: zluajit.State,
    f: *FD,
    buf: [*c]u8,
    len: usize,
    offset: zluajit.Integer,
) !c_int {
    const pread_task = try Task.init(L, .{
        .op = .{ .pread = .{
            .fd = f.fd,
            .buffer = .{ .slice = buf[0..len] },
            .offset = @intCast(offset),
        } },
        .callback = struct {
            pub fn callback(
                t: ?*anyopaque,
                _: *xev.Loop,
                _: *xev.Completion,
                result: xev.Result,
            ) xev.CallbackAction {
                const task: *Task = @ptrCast(@alignCast(t.?));
                defer task.deinit();

                const r = result.pread catch |err| {
                    task.L.pushBool(false);
                    task.L.pushString(@errorName(err));
                    task.failed();
                    return .disarm;
                };

                task.L.pushBool(true);
                task.L.pushInteger(@intCast(r));
                task.completed();
                return .disarm;
            }
        }.callback,
    });
    errdefer pread_task.deinit();

    AIO.loop.add(&pread_task.completion);

    return pread_task.started();
}

/// Closes FD.
fn close(
    L: zluajit.State,
    f: *FD,
) !c_int {
    const close_task = try Task.init(L, .{
        .op = .{ .close = .{ .fd = f.fd } },
        .callback = struct {
            pub fn callback(
                t: ?*anyopaque,
                _: *xev.Loop,
                _: *xev.Completion,
                result: xev.Result,
            ) xev.CallbackAction {
                const task: *Task = @ptrCast(@alignCast(t.?));
                defer task.deinit();

                result.close catch |err| {
                    task.L.pushBool(false);
                    task.L.pushString(@errorName(err));
                    task.failed();
                    return .disarm;
                };

                task.L.pushBool(true);
                task.completed();
                return .disarm;
            }
        }.callback,
    });
    errdefer close_task.deinit();

    AIO.loop.add(&close_task.completion);

    return close_task.started();
}

const testing = std.testing;

test "luaopen_aio" {
    const L = try zluajit.State.init(.{});
    try testing.expectEqual(1, luaopen_aio(L.lua));
}

test "sleep" {
    const S = struct {
        const Self = @This();

        var timer: std.time.Timer = undefined;
        var completed = false;
        var failed = false;

        fn startedCallback(
            _: zluajit.State,
            _: *Task,
        ) c_int {
            Self.timer = std.time.Timer.start() catch unreachable;
            return 0;
        }

        fn completedCallback(
            _: zluajit.State,
            _: *Task,
        ) void {
            Self.completed = true;
        }

        fn failedCallback(
            _: zluajit.State,
            _: *Task,
        ) void {
            Self.failed = true;
        }
    };
    Task.startedCallback = S.startedCallback;
    Task.completedCallback = S.completedCallback;
    Task.failedCallback = S.failedCallback;

    const L = try zluajit.State.init(.{});

    try testing.expectEqual(1, luaopen_aio(L.lua));
    L.setGlobal("aio");
    try L.doString("aio.sleep(0.5); aio.sleep(1) aio.poll('once')", null);

    try testing.expect(S.completed);
    try testing.expect(!S.failed);
    try testing.expect(S.timer.read() >= 5 * std.time.ns_per_ms);
}

test "open/read/close" {
    const S = struct {
        const Self = @This();

        var read_completed = false;
        var pread_completed = false;
        var close_completed = false;

        fn startedCallback(
            L: zluajit.State,
            _: *Task,
        ) c_int {
            return L.yield(0);
        }

        fn completedCallback(
            L: zluajit.State,
            task: *Task,
        ) void {
            switch (task.completion.op) {
                .read => {
                    read_completed = true;
                    _ = L.@"resume"(2) catch unreachable;
                },
                .pread => {
                    pread_completed = true;
                    _ = L.@"resume"(2) catch unreachable;
                },
                .close => {
                    close_completed = true;
                    _ = L.@"resume"(1) catch unreachable;
                },
                else => {},
            }
        }

        fn failedCallback(
            L: zluajit.State,
            _: *Task,
        ) void {
            L.@"error"();
        }
    };
    Task.startedCallback = S.startedCallback;
    Task.completedCallback = S.completedCallback;
    Task.failedCallback = S.failedCallback;

    const L = try zluajit.State.init(.{});
    L.openLibs();
    L.setGlobalAnyType("dump", struct {
        fn dump(l: zluajit.State) void {
            l.dumpStack();
        }
    }.dump);

    try testing.expectEqual(1, luaopen_aio(L.lua));
    L.setGlobal("aio");
    L.doString(
        \\function test()
        \\  local buffer = require("string.buffer")
        \\  local buf = buffer.new()
        \\  local ptr, len = buf:reserve(256)
        \\
        \\  -- OPEN
        \\  local f = aio.open("./src/testdata/file.txt", { read = true })
        \\
        \\  -- READ
        \\  local ok, r = aio.read(f, ptr, len)
        \\  assert(ok)
        \\  buf:commit(r)
        \\  assert(buf:tostring() == 'Hello world from a txt file!\n')
        \\  buf:reset()
        \\
        \\  -- PREAD
        \\  ok, r = aio.pread(f, ptr, len, 1)
        \\  assert(ok)
        \\  buf:commit(r)
        \\  assert(buf:tostring() == 'ello world from a txt file!\n')
        \\
        \\  -- CLOSE
        \\  assert(aio.close(f))
        \\  return
        \\end
    , null) catch L.dumpStack();

    const co = L.newThread();
    co.getGlobal("test");
    _ = co.@"resume"(0) catch co.dumpStack();

    try AIO.loop.run(.once);
    try AIO.loop.run(.once);
    try AIO.loop.run(.once);

    try testing.expect(S.read_completed);
    try testing.expect(S.pread_completed);
    try testing.expect(S.close_completed);
}
