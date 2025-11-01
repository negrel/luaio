const std = @import("std");
const zev = @import("zev");
const zluajit = @import("zluajit");

/// AIO defines a Lua userdata to perform asynchronous I/O.
pub fn AIO(_Io: type) type {
    _ = _Io;
    const Io = zev.Io;

    return struct {
        const Self = @This();
        const zluajitTName = "ljaio.AIO";

        loop: Io,

        pub fn init(L: zluajit.State, opts: Io.Options) !c_int {
            const self = L.newUserData(Self);

            L.pushValue(-1);
            L.setField(zluajit.Registry, zluajitTName);

            if (L.newMetaTableRef(Self)) |mt| {
                mt.set("__gc", Self.deinit);

                const index = L.newTableRef();
                defer L.pop(1);

                index.set("submit", Self.submit);
                index.set("poll", Self.poll);

                index.set("sleep", Self.sleep);

                const completed = L.newTableRef();
                defer L.pop(1);
                index.set("completed", completed);

                mt.set("__index", index);
            }
            L.setMetaTable(-2);

            try self.loop.init(opts);

            return 1;
        }

        fn submit(L: zluajit.State) !c_int {
            const self = L.checkAnyType(1, *Self);

            const submitted = try self.loop.submit();
            L.pushInteger(@intCast(submitted));
            return 1;
        }

        fn poll(L: zluajit.State) !c_int {
            const self = L.checkAnyType(1, *Self);
            const mode = L.checkEnum(2, zev.PollMode, .one);

            const completed = try self.loop.poll(mode);
            L.pushInteger(@intCast(completed));

            return 1;
        }

        fn sleep(L: zluajit.State) !c_int {
            const self = L.checkAnyType(1, *Self);
            const ms = L.checkAnyType(2, zluajit.Integer);

            const allocator = L.allocator().*;
            const op = try allocator.create(Io.Op(zev.TimeOut));
            op.* = Io.timeOut(
                .{ .ms = @intCast(ms) },
                @ptrCast(@alignCast(L.lua)),
                @ptrCast(&Self.callback),
            );

            _ = self.loop.queue(op) catch {
                _ = try self.loop.submit();
                _ = try self.loop.queue(op);
            };

            return L.yield(0);
        }

        fn callback(op: *Io.Op(zev.NoOp)) callconv(.c) void {
            const L: zluajit.State = .initFromCPointer(
                @ptrCast(op.header.user_data),
            );

            L.getField(zluajit.Registry, zluajitTName);
            defer L.pop(1);

            L.getField(-1, "completed");
            const completed = L.toAnyType(-1, zluajit.TableRef).?;
            defer L.pop(1);

            completed.set(
                L,
                switch (op.header.code) {
                    .noop, .timeout => true,
                    else => unreachable,
                },
            );

            // Free op.
            const allocator = L.allocator();
            inline for (@typeInfo(zev.OpCode).@"enum".fields) |field| {
                const variant: zev.OpCode = @enumFromInt(field.value);
                if (field.value == @intFromEnum(op.header.code)) {
                    allocator.destroy(
                        @as(*Io.Op(variant.Data()), @ptrCast(@alignCast(op))),
                    );
                    return;
                }
            }
        }

        fn deinit(self: *Self) void {
            self.loop.deinit();
        }
    };
}
