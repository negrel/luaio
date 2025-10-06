const std = @import("std");
const zluajit = @import("zluajit");
const xev = @import("xev");

export fn luaopen_aio(lua: ?*zluajit.c.lua_State) callconv(.c) c_int {
    const L = zluajit.State.initFromCPointer(lua.?);

    const mod = L.newTableRef();
    if (L.newMetaTableWithName("aio")) {
        AIO.init() catch unreachable;
        const mt = L.toAnyType(-1, zluajit.TableRef).?;
        mt.set("__gc", AIO.deinit);
        mt.set("__metatable", false);
    }
    L.setMetaTable(mod.ref.idx);

    mod.set("_poll", poll);
    mod.set("sleep", sleep);

    return 1;
}

/// Callback called when an async I/O task is started. This is called as a
/// return statement, you can yield, push data on the stack, etc.
export var luaio_task_started: ?*const fn (
    lua: ?*zluajit.c.lua_State,
    tkind: TaskKind,
    task: *anyopaque,
) callconv(.c) c_int = null;

/// Callback called when an async I/O task is completed.
export var luaio_task_completed: ?*const fn (
    lua: ?*zluajit.c.lua_State,
    tkind: TaskKind,
    task: *anyopaque,
) callconv(.c) void = null;

/// Callback called when an async I/O task is failed.
export var luaio_task_failed: ?*const fn (
    lua: ?*zluajit.c.lua_State,
    tkind: TaskKind,
    task: *anyopaque,
) callconv(.c) void = null;

/// TaskKind enumerates kind of async I/O task.
const TaskKind = enum(c_int) {
    sleep,
};

/// Asynchronous I/O state.
const AIO = struct {
    const Self = @This();

    pub var singleton: Self = undefined;

    loop: xev.Loop,
    tpool: xev.ThreadPool,

    fn init() !void {
        singleton.loop = try xev.Loop.init(.{});
        singleton.tpool = xev.ThreadPool.init(.{});
    }

    fn deinit() !void {
        singleton.loop.deinit();
        singleton.tpool.deinit();
    }
};

/// Poll polls event loop until one task complete or fail. If there is no task,
/// this function returns immediately.
fn poll() !void {
    try AIO.singleton.loop.run(.once);
}

/// Schedules a sleep task on the event loop.
fn sleep(L: zluajit.State, secs: zluajit.Number) !c_int {
    const SleepTask = Task(struct {
        timer: xev.Timer,

        fn callback(
            t: ?*Task(@This()),
            _: *xev.Loop,
            _: *xev.Completion,
            r: anyerror!void,
        ) xev.CallbackAction {
            const task = t.?;
            defer task.deinit();

            r catch {
                luaio_task_failed.?(task.L.lua, TaskKind.sleep, @ptrCast(task));
                return .disarm;
            };

            luaio_task_completed.?(task.L.lua, TaskKind.sleep, @ptrCast(task));
            return .disarm;
        }
    });

    const ms: u64 = @intFromFloat(secs * 1000);

    const task = try SleepTask.init(L, .{ .timer = try xev.Timer.init() });
    errdefer task.deinit();

    // Update loop cached time as sleep duration is relative to it. If we don't
    // do this, sleep may be shorter than duration provided by caller.
    AIO.singleton.loop.update_now();

    task.data.timer.run(
        &AIO.singleton.loop,
        &task.completion,
        ms,
        SleepTask,
        task,
        SleepTask.Data.callback,
    );

    return luaio_task_started.?(L.lua, TaskKind.sleep, @ptrCast(task));
}

/// Task defines an asynchronous I/O task.
fn Task(comptime T: type) type {
    return struct {
        const Self = @This();
        const Data = T;

        allocator: std.mem.Allocator,
        completion: xev.Completion,
        data: T,
        L: zluajit.State,

        /// Initialize a new I/O task that will suspend coroutine `L`. Task is
        /// allocated using Lua's allocator.
        fn init(L: zluajit.State, data: T) !*Self {
            const alloc = L.allocator().*;
            const self = try alloc.create(Self);
            self.allocator = alloc;
            self.L = L;
            self.data = data;
            return self;
        }

        /// Free I/O task memory.
        fn deinit(self: *const Self) void {
            self.allocator.destroy(self);
        }

        fn start() void {}
    };
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

        fn luaio_task_started(
            lua: ?*zluajit.c.lua_State,
            tkind: TaskKind,
            task: *anyopaque,
        ) callconv(.c) c_int {
            _ = lua;
            _ = tkind;
            _ = task;
            Self.timer = std.time.Timer.start() catch unreachable;
            return 0;
        }

        fn luaio_task_completed(
            lua: ?*zluajit.c.lua_State,
            tkind: TaskKind,
            task: *anyopaque,
        ) callconv(.c) void {
            _ = lua;
            _ = tkind;
            _ = task;
            Self.completed = true;
        }

        fn luaio_task_failed(
            lua: ?*zluajit.c.lua_State,
            tkind: TaskKind,
            task: *anyopaque,
        ) callconv(.c) void {
            _ = lua;
            _ = tkind;
            _ = task;
            Self.failed = true;
        }
    };
    luaio_task_started = S.luaio_task_started;
    luaio_task_completed = S.luaio_task_completed;
    luaio_task_failed = S.luaio_task_failed;

    const L = try zluajit.State.init(.{});
    L.openBase();

    try testing.expectEqual(1, luaopen_aio(L.lua));
    L.setGlobal("aio");
    try L.doString("aio.sleep(0.5); aio._poll()", null);

    try testing.expect(S.completed);
    try testing.expect(!S.failed);
    try testing.expect(S.timer.read() >= 5 * std.time.ns_per_ms);
}
