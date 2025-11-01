const std = @import("std");
pub const zluajit = @import("zluajit");
pub const zev = @import("zev");

const AIO = @import("aio.zig").AIO(zev.Io);

export fn luaopen_aio(lua: ?*zluajit.c.lua_State) callconv(.c) c_int {
    const L = zluajit.State.initFromCPointer(lua.?);
    return AIO.init(L, .{}) catch |err| L.raiseError(err);
}

inline fn luaTest(luacode: []const u8) !void {
    var dbg =
        std.heap.DebugAllocator(.{
            .safety = true,
            .verbose_log = true,
        }).init;
    defer _ = dbg.deinit();
    var allocator = dbg.allocator();

    const L = try zluajit.State.init(.{ .allocator = &allocator });
    defer L.deinit();
    L.openLibs();

    try L.doString(luacode, "testcase");
    std.debug.assert(luaopen_aio(L.lua) == 1);

    _ = L.pCall(1, 0, 0) catch |err| {
        L.dumpStack();
        return err;
    };
}

test "init/deinit" {
    try luaTest(
        \\return function(io) end
    );
}

test "sleep/pool" {
    var start = try std.time.Timer.start();
    try luaTest(
        \\return function(io)
        \\ local co = coroutine.create(function()
        \\  io:sleep(500)
        \\ end)
        \\ coroutine.resume(co)
        \\ io:submit()
        \\ io:poll()
        \\ assert(io.completed[co])
        \\end
    );
    try std.testing.expect(start.read() > 500 * std.time.ns_per_ms);
}
