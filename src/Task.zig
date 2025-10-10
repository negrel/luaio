//! Task defines an asynchronous I/O operation.

const std = @import("std");
const zluajit = @import("zluajit");
const xev = @import("xev");

const AIO = @import("./AIO.zig");

const Self = @This();

L: zluajit.State,
completion: xev.Completion,

/// Create and initialize a new task with provided data.
pub fn init(L: zluajit.State, comp: xev.Completion) !*Self {
    const self = try AIO.allocator.create(Self);
    self.L = L;
    self.completion = comp;
    if (self.completion.userdata == null) self.completion.userdata = self;
    return self;
}

/// Calls `luaio_task_started` callback.
pub fn started(self: *Self) c_int {
    std.debug.assert(self.completion.state() == .active);
    return luaio_task_started.?(self.L, self);
}

/// Calls `luaio_task_failed` callback.
pub fn failed(self: *Self) void {
    std.debug.assert(self.completion.state() == .dead);
    luaio_task_failed.?(self.L, self);
}

/// Calls `luaio_task_completed` callback.
pub fn completed(self: *Self) void {
    std.debug.assert(self.completion.state() == .dead);
    luaio_task_completed.?(self.L, self);
}

/// Free all resources associated to the dead task.
pub fn deinit(self: *Self) void {
    std.debug.assert(self.completion.state() == .dead);
    AIO.allocator.destroy(self);
}

/// Callback called when an async I/O task is started. This is called as a
/// return statement, you can yield, push data on the stack, etc.
pub export var luaio_task_started: ?*const fn (
    L: zluajit.State,
    task: *Self,
) c_int = null;

/// Callback called when an async I/O task is completed.
pub export var luaio_task_completed: ?*const fn (
    L: zluajit.State,
    task: *Self,
) void = null;

/// Callback called when an async I/O task is failed.
pub export var luaio_task_failed: ?*const fn (
    L: zluajit.State,
    task: *Self,
) void = null;
