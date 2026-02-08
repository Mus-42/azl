const std = @import("std");
const Alloc = std.mem.Allocator;

pub const bit_io = @import("bit_io.zig");
pub const huffman = @import("huffman.zig");
pub const sm = @import("string_matcher.zig");

test {
    _ = bit_io;
    _ = huffman;
    _ = sm;
}

pub const FLATE_MAX_LOOKBACK_DIST = 32 * 1024;
pub const FLATE_MAX_LOOKBACK_LEN = 258;
pub const FLATE_MIN_LOOKBACK_LEN = 3;
pub const FLATE_BUF_LEN = FLATE_MAX_LOOKBACK_DIST;
pub const FLATE_MAX_BLOCK_LEN = 1<<16;

const LIT_SYM_EXTRA_BITS: [30]u4 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 0 };
const LIT_SYM_OFFSETS: [30]u16 = .{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258, 0 };

const DIST_SYM_EXTRA_BITS: [30]u4 =.{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const DIST_SYM_OFFSETS: [30]u16 = .{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };

const DYNAMIC_HC_LEN_CODES_LEN_ORDER: [19]u8 = .{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };


const lit_huffman = huffman.Huffman(286, 15, 9);
const dist_huffman = huffman.Huffman(30, 15, 9);
const code_len_huffman = huffman.Huffman(19, 7, 5);

const BlockType = enum (u2) {
    stored  = 0b00,
    static  = 0b01,
    dynamic = 0b10,
};

const Decompressor = struct {
    // interface: std.Io.Reader,
    input: *std.Io.Reader,
    bit_reader: bit_io.BitReader = .{},

    // TODO rename to something
    buf_end: usize = 0,
    buf: *[FLATE_BUF_LEN]u8,

    lit_tree: lit_huffman.Decoder = undefined,
    dist_tree: dist_huffman.Decoder = undefined,

    state: State = .reading,

    const Self = @This();

    const State = enum {
        reading,
        ended,
        invalid,
    };

    fn init(input: *std.Io.Reader, buf: *[FLATE_BUF_LEN]u8) Self {
        std.debug.assert(input.buffer.len > 0);

        return .{
            .input = input,
            .buf = buf,
        };
    }

    fn readDynamicBlockHuffmanTrees(self: *Self) !void { 
        const n_lit = try self.bit_reader.takeBits(self.input, 5) + 257;
        const n_dist = try self.bit_reader.takeBits(self.input, 5) + 1;
        const n_code_len = try self.bit_reader.takeBits(self.input, 4) + 4;

        if (n_code_len > 19 or n_dist > 30 or n_lit > 286)
            return error.InvalidCodeLen;

        var code_len_lengths: [19]u4 = @splat(0);
        for (DYNAMIC_HC_LEN_CODES_LEN_ORDER[0..n_code_len]) |i| {
            code_len_lengths[i] = try self.bit_reader.takeUint(self.input, u3);
        }

        var code_len_tree: code_len_huffman.Decoder = try .initLen(&code_len_lengths);

        var code_len: [286 + 30]u4 = @splat(0);
        var i: usize = 0;
        const n_lit_dist = n_lit + n_dist;
        while (i < n_lit_dist) {
            const len_sym = try code_len_tree.readSymbol(&self.bit_reader, self.input);
            if (len_sym < 16) {
                code_len[i] = @intCast(len_sym);
                i += 1;
                continue;
            }

            if (len_sym == 17) {
                i += @as(usize, try self.bit_reader.takeUint(self.input, u3)) + 3;
                continue;
            } else if (len_sym == 18) {
                i += @as(usize, try self.bit_reader.takeUint(self.input, u7)) + 11;
                continue;
            }
            if (i == 0) 
                return error.InvalidBlockHeader;
            const num = @as(usize, try self.bit_reader.takeUint(self.input, u2)) + 3;
            const val = code_len[i-1];
            for (0..@min(num, code_len.len-i)) |_| {
                code_len[i] = val;
                i += 1;
            }
        }

        self.lit_tree = try .initLen(code_len[0..n_lit]);
        self.dist_tree = try .initLen(code_len[n_lit..][0..n_dist]);
    }


    fn writeByte(self: *Self, w: *std.io.Writer, byte: u8) !void {
        try w.writeByte(byte);
        // TODO on error set state to "broken"
        self.buf[self.buf_end] = byte;
        self.buf_end += 1;
        self.buf_end &= FLATE_BUF_LEN - 1;
    }

    fn bufTailForWrite(self: *Self, max_len: usize) []u8 {
        const len = @min(FLATE_BUF_LEN - self.buf_end, max_len);
        const slice = self.buf[self.buf_end..][0..len];
        self.buf_end += len;
        self.buf_end &= FLATE_BUF_LEN - 1;
        return slice;
    }

    // TODO rename to something like "pipe" or idk
    fn writeStreaming(self: *Self, w: *std.Io.Writer, limit: usize) !void {
        var remaining = limit;
        if (remaining > FLATE_BUF_LEN) {
            try self.input.streamExact(w, remaining - FLATE_BUF_LEN);
            remaining = FLATE_BUF_LEN;
        }
        
        while (remaining != 0) {
            const buf = self.bufTailForWrite(remaining);
            try self.input.readSliceAll(buf);
            try w.writeAll(buf);
            remaining -= buf.len;
        }
    }

    fn processWholeStream(self: *Self, w: *std.io.Writer) !usize {
        var total_size: usize = 0;
        while (self.state == .reading) {
            total_size += try self.processSingleBlock(w);
        }
        return total_size;
    }

    fn processSingleBlock(self: *Self, w: *std.io.Writer) !usize {
        const is_final = try self.bit_reader.takeUint(self.input, u1) != 0;
        if (is_final) {
            // we trust this flag and didn't verify if that's the case
            self.state = .ended;
        }
        const block_type_num = try self.bit_reader.takeUint(self.input, u2);
        const block_type = std.enums.fromInt(BlockType, block_type_num) orelse return error.InvalidBlockType;

        switch (block_type) {
            .stored => {
                const len = self.input.takeInt(u16, .little) catch return error.InvalidBlockHeader;
                const nlen = self.input.takeInt(u16, .little) catch return error.InvalidBlockHeader;

                if (len != ~nlen)
                    return error.InvalidBlockHeader;

                try self.writeStreaming(w, len);
                self.bit_reader.byteAlignDiscarding();
                return len;
            },
            .static => {
                self.lit_tree = .initStatic();
                self.dist_tree = .initStatic();
            },
            .dynamic => {
                try self.readDynamicBlockHuffmanTrees();
            },
        }

        // TODO handle error.EndOfStream
        return self.decodeBlockCode(w);
    }
    
    fn decodeBlockCode(self: *Self, w: *std.io.Writer) !usize {
        var written: usize = 0;
        while (true) {
            const sym = try self.lit_tree.readSymbol(&self.bit_reader, self.input);
            if (sym < 256) {
                try self.writeByte(w, @intCast(sym));
                written += 1;
                continue;
            }
            if (sym == 256)
                break;
            if (sym >= 286)
                return error.InvalidSymbolUsed;
         
            const len_extra = try self.bit_reader.takeBits(self.input, LIT_SYM_EXTRA_BITS[sym - 257]);
            const len = len_extra + LIT_SYM_OFFSETS[sym - 257];
            const dist_sym = try self.dist_tree.readSymbol(&self.bit_reader, self.input);
            const dist_extra = try self.bit_reader.takeBits(self.input, DIST_SYM_EXTRA_BITS[dist_sym]);
            const dist = dist_extra + DIST_SYM_OFFSETS[dist_sym];

            if (dist > FLATE_BUF_LEN)
                return error.InvalidBufferLen;

            // TODO make that smarter
            for (0..len) |_| {
                const index = (self.buf_end + FLATE_BUF_LEN - dist) & (FLATE_BUF_LEN - 1);
                try self.writeByte(w, self.buf[index]);
                written += 1;
            }
        }
        return written;
    }
};

/// decompresses flate stream until stream reaches final block or error is returned
pub fn decompress(source: *std.io.Reader, sink: *std.io.Writer) !usize {
    const bufs = struct  {
        threadlocal var buf: [FLATE_BUF_LEN]u8 = undefined;
    };
    var dec: Decompressor = .init(source, &bufs.buf);
    return try dec.processWholeStream(sink);
}

const Compressor = struct {
    data: []const u8,
    matcher: *sm.StringMatcher,
    sink: *std.io.Writer = undefined,
    bit_writer: bit_io.BitWriter = .{},
    lit_tree: lit_huffman.Encoder = undefined,
    dist_tree: dist_huffman.Encoder = undefined,

    pub const BlockContext = struct {
    };

    const Self = @This();

    fn init(alloc: Alloc, data: []const u8, matcher: *sm.StringMatcher) !Self {
        _ = alloc;
        matcher.* = .{ .data = data, .match_limits = .fromPreset(.fast) };

        return .{ 
            .data = data,
            .matcher = matcher,
        };
    }

    fn deinit(self: *Self, alloc: Alloc) void {
        _ = self;
        _ = alloc;
    }

    fn lenToSym(len: u16) u16 {
        for (0.., LIT_SYM_OFFSETS[1..29]) |i, sym_offset| {
            if (len < sym_offset) {
                return @intCast(i + 257);
            }
        }
        return 28 + 257;
    }

    fn distToSym(dist: u16) u16 {
        for (0.., DIST_SYM_OFFSETS[1..]) |i, sym_offset| {
            if (dist < sym_offset) {
                return @intCast(i);
            }
        }
        return 29;
    }

    fn writeDynamicBlockHuffmanTree(self: *Self, sink: *std.Io.Writer) !void {
        const MAX_LEN = 286 + 30;
        var code_len_encoded: [MAX_LEN]u8 = undefined;
        var code_len_extra: [MAX_LEN]u8 = undefined;

        var n_lit = self.lit_tree.lengths.len;
        while (n_lit > 257 and self.lit_tree.lengths[n_lit-1] == 0) {
            n_lit -= 1;
        }

        var n_dist = self.dist_tree.lengths.len;
        while (n_dist > 257 and self.dist_tree.lengths[n_dist-1] == 0) {
            n_dist -= 1;
        }

        // TODO clean it up. looks horrible.
        var cur_code: usize = 0;
        for (&[2][]const u4{self.lit_tree.lengths[0..n_lit], self.dist_tree.lengths[0..n_dist]}) |code_len| {
            var i: usize = 0;
            while (i < code_len.len) {
                // try to encode multiple zeros
                var j = i;
                while (j < code_len.len and code_len[j] == 0) {
                    j += 1;
                }
                if (j-i >= 3) {
                    if (j-i >= 11) {
                        const dist = @min(j-i, 11 + std.math.maxInt(u7));
                        code_len_encoded[cur_code] = 18;
                        code_len_extra[cur_code] = @intCast(dist - 11);
                        cur_code += 1;
                        i += dist;
                        continue;
                    }
                    code_len_encoded[cur_code] = 17;
                    code_len_extra[cur_code] = @intCast(j - i - 3);
                    cur_code += 1;
                    i = j;
                    continue;
                }
                j = i+1;
                while (j < code_len.len and code_len[i] == code_len[j]) {
                    j += 1;
                }

                code_len_encoded[cur_code] = code_len[i];
                cur_code += 1;
                i += 1;

                if (j-i >= 3) {
                    const dist = @min(j-i, 3 + std.math.maxInt(u2));
                    code_len_encoded[cur_code] = 16;
                    code_len_extra[cur_code] = @intCast(dist - 3);
                    cur_code += 1;
                    i += dist;
                }
            }
        }

        var code_len_freq: [19]u16 = @splat(0);
        for (code_len_encoded[0..cur_code]) |code| {
            code_len_freq[code] += 1;
        }
        const code_len_tree: code_len_huffman.Encoder = .initFreq(&code_len_freq);

        var n_code_len: usize = DYNAMIC_HC_LEN_CODES_LEN_ORDER.len;
        while (n_code_len > 4 and code_len_tree.lengths[DYNAMIC_HC_LEN_CODES_LEN_ORDER[n_code_len-1]] == 0) {
            n_code_len -= 1;
        }

        try self.bit_writer.writeBits(sink, @as(u5, @intCast(n_lit - 257)), 5);
        try self.bit_writer.writeBits(sink, @as(u5, @intCast(n_dist - 1)), 5);
        try self.bit_writer.writeBits(sink, @as(u4, @intCast(n_code_len - 4)), 4);

        for (DYNAMIC_HC_LEN_CODES_LEN_ORDER[0..n_code_len]) |i| {
            try self.bit_writer.writeUint(sink, u3, @intCast(code_len_tree.lengths[i]));
        }

        for (code_len_encoded[0..cur_code], code_len_extra[0..cur_code]) |code, extra| {
            try code_len_tree.writeSymbol(&self.bit_writer, sink, @intCast(code));
            if (code == 16) {
                try self.bit_writer.writeUint(sink, u2, @intCast(extra));
            } else if (code == 17) {
                try self.bit_writer.writeUint(sink, u3, @intCast(extra));
            } else if (code == 18) {
                try self.bit_writer.writeUint(sink, u7, @intCast(extra));
            }
        }
    }

    // compress [start, end) chunk of data
    fn compressBlock(
        self: *Self,
        sink: *std.Io.Writer,
        bl_start: u32,
        bl_end: u32,
        is_final: bool
    ) !void {
        const data = self.data;
        
        var lit_freq: [286]u16 = @splat(0);
        var dist_freq: [30]u16 = @splat(0);

        lit_freq[256] = 1;

        // TODO reunning this 2 times in unreliable.
        // TODO run once and store results
        var cursor = bl_start;
        while (cursor < bl_end) {
            self.matcher.seekTo(cursor);
            const max_len = bl_end - cursor;
            if (self.matcher.findLongestMatch(max_len)) |match| {
                const lit_sym = lenToSym(match.len);
                const dist_sym = distToSym(match.dist);

                const approx_len = @as(u32, 24) + LIT_SYM_EXTRA_BITS[lit_sym - 257] + DIST_SYM_EXTRA_BITS[dist_sym];
                if (approx_len < match.len * 8) {
                    lit_freq[lit_sym] += 1;
                    dist_freq[dist_sym] += 1;
                    cursor += match.len;
                    continue;
                }
            } 
            lit_freq[data[cursor]] += 1;
            cursor += 1;
        }

        // TODO decide between stored/static/dynamic
        var block_type: BlockType = .dynamic;
        _ = &block_type;

        try self.bit_writer.writeUint(sink, u1, @intFromBool(is_final));
        try self.bit_writer.writeUint(sink, u2, @intFromEnum(block_type));

        switch (block_type) {
            .stored => {
                @panic("TODO");
            },
            .static => {
                self.lit_tree = .initStatic();
                self.dist_tree = .initStatic();
            },
            .dynamic => {
                self.lit_tree = .initFreq(&lit_freq);
                self.dist_tree = .initFreq(&dist_freq);
                try self.writeDynamicBlockHuffmanTree(sink);
            },
        }

        cursor = bl_start;
        while (cursor < bl_end) {
            self.matcher.seekTo(cursor);
            const max_len = bl_end - cursor;
            if (self.matcher.findLongestMatch(max_len)) |match| {
                const lit_sym = lenToSym(match.len);
                const dist_sym = distToSym(match.dist);
                
                const approx_len = @as(u32, 24) + LIT_SYM_EXTRA_BITS[lit_sym - 257] + DIST_SYM_EXTRA_BITS[dist_sym];
                if (approx_len < match.len * 8) {
                    std.debug.assert(lit_freq[lit_sym] > 0);
                    std.debug.assert(dist_freq[dist_sym] > 0);

                    const len_extra = match.len - LIT_SYM_OFFSETS[lit_sym - 257];
                    const dist_extra = match.dist - DIST_SYM_OFFSETS[dist_sym];

                    const len_bits = LIT_SYM_EXTRA_BITS[lit_sym - 257];
                    const dist_bits = DIST_SYM_EXTRA_BITS[dist_sym];


                    try self.lit_tree.writeSymbol(&self.bit_writer, sink, @intCast(lit_sym));
                    if (len_bits > 0) {
                        try self.bit_writer.writeBits(sink, len_extra, len_bits);
                    }
                    try self.dist_tree.writeSymbol(&self.bit_writer, sink, @intCast(dist_sym));
                    if (dist_bits > 0) {
                        try self.bit_writer.writeBits(sink, dist_extra, dist_bits);
                    }
                    
                    cursor += match.len;
                    continue;
                }
            }

            try self.lit_tree.writeSymbol(&self.bit_writer, sink, data[cursor]);
            cursor += 1;
        }
        // end of block
        try self.lit_tree.writeSymbol(&self.bit_writer, sink, 256);
    }

    pub fn compress(self: *Self, sink: *std.io.Writer, data: []const u8) !void {
        var i: usize = 0;
        while (i < data.len) {
            const beg = i;
            i += FLATE_MAX_BLOCK_LEN;
            const is_final = i >= data.len;
            const bl_start: u32 = @intCast(beg);
            const bl_end: u32 = @intCast(@min(i, data.len));
            try self.compressBlock(sink, bl_start, bl_end, is_final);
            // std.debug.print("block: {}/{}\n", .{i/FLATE_MAX_BLOCK_LEN, data.len/FLATE_MAX_BLOCK_LEN+1});
        }
        try self.bit_writer.flushByteAligned(sink);
    }
};


/// compresses data into flate stream
/// limitations: data should be fully read into memory
pub fn compress(data: []const u8, sink: *std.io.Writer, alloc: Alloc) !void {
    const bufs = struct {
        threadlocal var matcher: sm.StringMatcher = undefined;
    };

    var comp: Compressor = try .init(alloc, data, &bufs.matcher);
    defer comp.deinit(alloc);
    try comp.compress(sink, data);
}


fn testFlateOn(data: []const u8) !void {
    if (data.len == 0) return; // TODO
    const alloc = std.testing.allocator;
    var compression_buf: std.Io.Writer.Allocating = .init(alloc);
    defer compression_buf.deinit(); 
    try compress(data, &compression_buf.writer, alloc);
    var decompression_buf: std.Io.Writer.Allocating = .init(alloc);
    defer decompression_buf.deinit(); 
    var source: std.Io.Reader = .fixed(compression_buf.written());
    _ = try decompress(&source, &decompression_buf.writer);

    try std.testing.expectEqual(0, source.bufferedLen());
    try std.testing.expectEqualSlices(u8, data, decompression_buf.written());
}

// TODO when zig's builtin fuzzer would be good enough relace that with fuzzer/add fuzzer?
test "flate compress-decompress" {
    const INPUTS: []const []const u8 = &.{
        "a",
        "aaaaaaaa",
        "abababab",
        "abcdefgh",
        "abcdabcd",
        // TODO
    };

    for (INPUTS) |data| {
        try testFlateOn(data);
    }
}
