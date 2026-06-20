const std = @import("std");

pub const BitReader = struct {
    buffered: u32 = 0,
    buffered_count: u5 = 0,

    const Self = @This();

    pub fn byteAlignDiscarding(self: *Self) void {
        self.buffered_count = 0;
        self.buffered = 0;
    }

    pub fn takeBits(self: *Self, input: *std.Io.Reader, count: u4) !u16 {
        const bits = try self.peekBits(input, count);
        self.tossBits(input, count);
        return bits;
    }

    pub fn takeUint(self: *Self, input: *std.Io.Reader, comptime U: type) !U {
        return @intCast(try self.takeBits(input, @intCast(@bitSizeOf(U))));
    }

    pub fn peekBits(self: *Self, input: *std.Io.Reader, count: u4) !u16 {
        if (count == 0) return 0;
        while (count > self.buffered_count) {
            const buf = self.buffered_count;
            const pos = buf >> 3;
            self.buffered_count += 8;
            const byte = if (input.peek(pos+1)) |slice| slice[pos] else |err| {
                @branchHint(.unlikely);
                switch (err) {
                    // handle EoS as zeros
                    // for trusted files that part would be newer used
                    error.EndOfStream => continue,
                    else => return err,
                }
            };
            // std.debug.print("0x{X:0}\n", .{byte});
            self.buffered |= @as(u32, byte) << buf;
        }
        const ret = self.buffered & ((@as(u32, 1)<<count)-1);
        // std.debug.print("{b:0<[1]}\n", .{ret, count});
        return @intCast(ret);
    }

    pub fn tossBits(self: *Self, input: *std.Io.Reader, count: u4) void {
        std.debug.assert(self.buffered_count >= count);
        if (count == 0) return;
        const to_toss = (@as(u5, count) -| (self.buffered_count&7) + 7) >> 3;
        // std.debug.print("tossed: {}\n", .{to_toss});
        input.toss(to_toss);
        self.buffered_count -= count;
        self.buffered >>= count;
    }
};

pub const BitWriter = struct {
    buffered: u32 = 0,
    buffered_count: u5 = 0,

    const Self = @This();
    
    /// flush all remaining bits and align to byte boundry
    pub fn flushByteAligned(self: *Self, sink: *std.Io.Writer) !void {
        // round to next multiple of 8
        self.buffered_count = (self.buffered_count + 7) & ~@as(u5, 0b11);
        try self.partialFlushBuffered(sink);
        self.buffered_count = 0;
        self.buffered = 0;
    }

    pub fn writeBits(self: *Self, sink: *std.Io.Writer, bits: u16, count: u4) !void {
        self.buffered |= @as(u32, bits) << self.buffered_count;
        self.buffered_count += count;
        try self.partialFlushBuffered(sink);
    }

    pub fn writeUint(self: *Self, sink: *std.Io.Writer, comptime U: type, bits: U) !void {
        return try self.writeBits(sink, bits, @intCast(@bitSizeOf(U)));
    }

    pub fn partialFlushBuffered(self: *Self, sink: *std.Io.Writer) !void {
        while (self.buffered_count >= 8) {
            try sink.writeByte(@intCast(self.buffered & 0xFF));
            self.buffered_count -= 8;
            self.buffered >>= 8;
        }
    }
};
