//! luaio global state.

const std = @import("std");
const zluajit = @import("zluajit");
const xev = @import("xev");

const Self = @This();

pub var L: zluajit.State = undefined;
pub var allocator: std.mem.Allocator = undefined;
pub var loop: xev.Loop = undefined;

pub fn init(lua: zluajit.State) !void {
    L = lua;
    allocator = L.allocator().*;
    loop = try xev.Loop.init(.{});
}

pub fn poll(mode: xev.RunMode) !void {
    try loop.run(mode);
}

pub fn deinit() !void {
    loop.deinit();
}
