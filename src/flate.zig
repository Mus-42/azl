const std = @import("std");
const Alloc = std.mem.Allocator;

pub const FLATE_BUF_LEN = 32 * 1024;

const FLATE_MAX_BLOCK_LEN = 1<<16;

const LIT_SYM_EXTRA_BITS: [30]u4 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 0 };
const LIT_SYM_OFFSETS: [30]u16 = .{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258, 0 };

const DIST_SYM_EXTRA_BITS: [30]u4 =.{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const DIST_SYM_OFFSETS: [30]u16 = .{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };

const DYNAMIC_HC_LEN_CODES_LEN_ORDER: [19]u8 = .{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

const BitReader = struct {
    buffered: u32 = 0,
    buffered_count: u5 = 0,

    const Self = @This();

    fn byteAlignDiscarding(self: *Self) void {
        self.buffered_count = 0;
        self.buffered = 0;
    }

    fn takeBits(self: *Self, input: *std.io.Reader, count: u4) !u16 {
        const bits = try self.peekBits(input, count);
        self.tossBits(input, count);
        return bits;
    }

    fn takeUint(self: *Self, input: *std.io.Reader, comptime U: type) !U {
        return @intCast(try self.takeBits(input, @intCast(@bitSizeOf(U))));
    }

    fn peekBits(self: *Self, input: *std.io.Reader, count: u4) !u16 {
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

    fn tossBits(self: *Self, input: *std.io.Reader, count: u4) void {
        std.debug.assert(self.buffered_count >= count);
        if (count == 0) return;
        const to_toss = (@as(u5, count) -| (self.buffered_count&7) + 7) >> 3;
        // std.debug.print("tossed: {}\n", .{to_toss});
        input.toss(to_toss);
        self.buffered_count -= count;
        self.buffered >>= count;
    }
};

const BitWriter = struct {
    buffered: u32 = 0,
    buffered_count: u5 = 0,

    const Self = @This();
    
    /// flush all remaining bits and align to byte boundry
    fn flushByteAligned(self: *Self, sink: *std.io.Writer) !void {
        // round to next multiple of 8
        self.buffered_count = (self.buffered_count + 7) & ~@as(u5, 0b11);
        try self.partialFlushBuffered(sink);
        self.buffered_count = 0;
        self.buffered = 0;
    }

    fn writeBits(self: *Self, sink: *std.io.Writer, bits: u16, count: u4) !void {
        self.buffered |= @as(u32, bits) << self.buffered_count;
        self.buffered_count += count;
        try self.partialFlushBuffered(sink);
    }

    fn writeUint(self: *Self, sink: *std.io.Writer, comptime U: type, bits: U) !void {
        return try self.writeBits(sink, bits, @intCast(@bitSizeOf(U)));
    }

    fn partialFlushBuffered(self: *Self, sink: *std.io.Writer) !void {
        while (self.buffered_count >= 8) {
            try sink.writeByte(@intCast(self.buffered & 0xFF));
            self.buffered_count -= 8;
            self.buffered >>= 8;
        }
    }
};


// Literal/length codes tree
const LitHuffmanTree = HuffmanTree(286, 15);
// Distance codes tree
const DistHuffmanTree = HuffmanTree(30, 15);
// Code lengths tree
const CodeLenHuffmanTree = HuffmanTree(19, 7);

fn HuffmanTree(comptime max_nodes: usize, comptime max_code_bits: u4) type {
    return struct {
        nodes: [max_nodes]TreeNode,
        len_sub_max: u4,
        len_min: u4,
        len_counts: [max_code_bits]u16,
        len_lookup: [max_code_bits]u16,

        const TreeNode = packed struct {
            code: u15 = 0,
            // 0 means not used
            code_len: u4 = 0,
            symbol: u9 = 0,
        };
        
        const Self = @This();

        fn init(self: *Self, lengths: []const u4) void {
            std.debug.assert(lengths.len <= max_nodes);
            //std.debug.print("lengths = {any}\n", .{lengths});
            self.clear();
            for (0.., self.nodes[0..lengths.len], lengths) |i, *node, len| {
                node.symbol = @intCast(i);
                node.code_len = len;
            }
            self.orderNodes();
            self.updateLenCounts();
            self.rebuildCodesFromLengths();
            self.rebuildLenLookup();
        }

        fn initLitStatic(self: *Self) void {
            comptime { std.debug.assert(max_nodes == 286); }

            self.clear();
            for (0.., &self.nodes) |i, *node| {
                node.symbol = @intCast(i);
                if (i < 144) { node.code_len = 8; }
                else if (i < 256) { node.code_len = 9; }
                else if (i < 280) { node.code_len = 7; }
                else { node.code_len = 8; }
            }
            self.orderNodes();
            self.updateLenCounts();
            // Symbols 286-287 (len 8) participate in code consturction but not present in actual tree
            self.len_counts[8-1] += 2;
            self.rebuildCodesFromLengths();
            self.len_counts[8-1] -= 2;
            self.rebuildLenLookup();
        }

        fn initDistStatic(self: *Self) void {
            comptime { std.debug.assert(max_nodes == 30); }

            self.clear();
            for (0.., &self.nodes) |i, *node| {
                node.symbol = @intCast(i);
                node.code_len = 5;
            }
            self.orderNodes();
            self.updateLenCounts();
            self.rebuildCodesFromLengths();
            self.rebuildLenLookup();
        }

        fn debugDump(self: *const Self) void {
            for (&self.nodes) |node| {
                if (node.code_len > 0) {
                    std.debug.print("{d:03} {b:0>[2]}\n", .{node.symbol, node.code, node.code_len});
                }
            }
        }

        fn clear(self: *Self) void {
            @memset(&self.nodes, .{});
        }

        fn updateLenCounts(self: *Self) void {
            self.len_counts = @splat(0);
            for (&self.nodes) |node| {
                if (node.code_len > 0) {
                    self.len_counts[node.code_len - 1] += 1;
                }
            }
            for (0..max_code_bits) |i| {
                const k = max_code_bits - 1 - i;
                if (self.len_counts[k] != 0) {
                    self.len_sub_max = @intCast(i);
                    break;
                }
            }
            for (0..max_code_bits) |i| {
                if (self.len_counts[i] != 0) {
                    self.len_min = @intCast(i);
                    break;
                }
            }
        }

        fn rebuildCodesFromLengths(self: *Self) void {
            var code: u16 = 0;
            var next_code: [max_code_bits]u16 = @splat(0);
            for (1..max_code_bits) |bits| {
                code += self.len_counts[bits-1];
                code <<= 1;
                next_code[bits] = code;
            }

            // std.debug.print("len_counts = {any}\n", .{self.len_counts});
            // std.debug.print("next_code = {any}\n", .{next_code});

            for (&self.nodes) |*node| {
                if (node.code_len == 0)
                    continue;
                node.code = @intCast(next_code[node.code_len - 1]);
                next_code[node.code_len - 1] += 1;
            }
        }

        fn nodeLenCmp(_: void, a: TreeNode, b: TreeNode) bool {
            if (a.code_len != b.code_len) {
                return a.code_len < b.code_len;
            }
            return a.symbol < b.symbol;
        }

        fn orderNodes(self: *Self) void {
            std.sort.heap(TreeNode, &self.nodes, {}, nodeLenCmp);
        }

        fn rebuildLenLookup(self: *Self) void {
            var i: u16 = 0;

            while (i < self.nodes.len and self.nodes[i].code_len == 0) {
                i += 1;
            }

            for (0..max_code_bits) |bits| {
                self.len_lookup[bits] = i;
                i += self.len_counts[bits];
            }

            std.debug.assert(i == self.nodes.len);
        }

        fn readSymbol(self: *Self, bit_reader: *BitReader, input: *std.Io.Reader) !u15 {
            const code_len = max_code_bits - self.len_sub_max;
            var code = @bitReverse(try bit_reader.peekBits(input, code_len));
            code >>= @intCast(@as(u16, 16) - code_len);
            const node_index = try self.lookupSymbolNodeIndex(code, code_len);
            bit_reader.tossBits(input, @intCast(self.nodes[node_index].code_len));
            return self.nodes[node_index].symbol;
        }

        fn lookupSymbolNodeIndex(self: *Self, code: u16, code_len: u4) !u16 {
            // TODO some kind of smart lookup for short codes here???
            return self.lookupSymbolNodeIndexFull(code, code_len);
        }

        fn lookupSymbolNodeIndexFull(self: *Self, code: u16, code_len: u4) !u16 {
            if (self.len_min >= code_len) 
                return error.InvalidHuffmanCode;

            for (self.len_min..code_len) |i| {
                const len = self.len_counts[i];
                if (len == 0) continue;
                const code_i = code >> @intCast(code_len - i - 1);
                const j = self.len_lookup[i];
                const min_code = self.nodes[j].code;
                if (min_code <= code_i and code_i - min_code < len) {
                    const index = j + code_i - min_code;
                    std.debug.assert(self.nodes[index].code == code_i);
                    return index;
                }
            }

            return error.InvalidHuffmanCode;
        }

        // TODO make make it faster
        fn writeSymbol(self: *Self, bit_writer: *BitWriter, sink: *std.Io.Writer, symbol: u9) !void {
            for (&self.nodes) |node| {
                if (node.symbol != symbol) {
                    continue;
                }
                try bit_writer.writeBits(sink, @bitReverse(node.code) >> (15 - node.code_len), node.code_len);
                return;
            }
            return error.InvalidHuffmanTreeSymbol;
        }
    };
}

const BlockType = enum (u2) {
    stored  = 0b00,
    static  = 0b01,
    dynamic = 0b10,
};

const Decompressor = struct {
    // interface: std.Io.Reader,
    input: *std.Io.Reader,
    bit_reader: BitReader = .{},

    // TODO rename to something
    buf_end: usize = 0,
    buf: *[FLATE_BUF_LEN]u8,

    lit_tree: LitHuffmanTree = undefined,
    dist_tree: DistHuffmanTree = undefined,

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

        var code_len_tree: CodeLenHuffmanTree = undefined;
        code_len_tree.init(&code_len_lengths);

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

        self.lit_tree.init(code_len[0..n_lit]);
        self.dist_tree.init(code_len[n_lit..][0..n_dist]);
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

    // fn streamImpl(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    //     std.debug.assert(limit == .unlimited);
    //     const self: *Self = @fieldParentPtr("interface", r);
    //     if (self.state == .ended) {
    //         return error.EndOfStream;
    //     }
    //     if (self.state == .invalid) {
    //         return error.ReadFailed;
    //     }
    //     return self.processSingleBlock(w) catch |err| switch (err) {
    //         // TODO handle errors in a smart way???
    //         error.EndOfStream => {
    //             self.state = .invalid;
    //             return error.ReadFailed;
    //         },
    //         else => {
    //             self.state = .invalid;
    //             return error.ReadFailed;
    //         }
    //     };
    // }

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
                self.lit_tree.initLitStatic();
                self.dist_tree.initDistStatic();
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
pub fn decompress(source: *std.io.Reader, sink: *std.io.Writer, buf: *[FLATE_BUF_LEN]u8) !usize {
    var dec: Decompressor = .init(source, buf);
    return try dec.processWholeStream(sink);
}

const Compressor = struct {
    alloc: Alloc,
    data: []const u8,
    lit_count: [286]u16 = @splat(0),
    dist_count: [30]u16 = @splat(0),
    sink: *std.io.Writer,
    bit_writer: BitWriter = .{},
    lit_tree: LitHuffmanTree = undefined,
    dist_tree: DistHuffmanTree = undefined,

    const Self = @This();

    fn init(alloc: Alloc, sink: *std.io.Writer, data: []const u8) Self {
        return .{
            .alloc = alloc,
            .data = data,
            .sink = sink,
        };
    }

    const Match = struct {
        len: u16,
        dist: u16,
    };

    fn tryFindMatch(self: *Self, position: usize) ?Match {
        // for k in 3..
        // start in @max(0, pos-MAX_LOOKBACK)..pos+k-1
        // end = start + k

        _ = position;
        _ = self;
        // TODO
        return null;
    }

    fn lenToSym(len: u16) u16 {
        for (0.., LIT_SYM_OFFSETS[1..]) |i, sym_offset| {
            if (len > sym_offset) {
                return i + 257;
            }
        }
        return 30 + 257;
    }

    fn distToSym(dist: u16) u16 {
        for (0.., DIST_SYM_OFFSETS[1..]) |i, sym_offset| {
            if (dist > sym_offset) {
                return i;
            }
        }
        return 30;
    }

    // compress [start, end) chunk of data
    fn compressBlock(self: *Self, bl_start: usize, bl_end: usize, is_final: bool) !void {
        var block_type: BlockType = .static;
        _ = &block_type;
        // self.cursor = 0;
        // self.lit_count = @splat(0);
        // self.dist_count = @splat(0);
        // self.sym_count[256] = 1;
        // while (self.cursor < self.data.len) {
        //     if (self.tryFindMatch()) |match| {
        //         const lit_sym = lenToSym(match.len);
        //         const dist_sym = distToSym(match.dist);
        //         self.lit_count[lit_sym] += 1;
        //         self.dist_count[dist_sym] += 1;
        //         self.cursor += match.len;
        //     } else {
        //         self.lit_count[self.data[self.cursor]] += 1;
        //         self.cursor += 1;
        //     }
        // }
        // TODO decide between stored/static/dynamic


        try self.bit_writer.writeUint(self.sink, u1, @intFromBool(is_final));
        try self.bit_writer.writeUint(self.sink, u2, @intFromEnum(block_type));

        switch (block_type) {
            .stored => {
                @panic("TODO");
            },
            .static => {
                self.lit_tree.initLitStatic();
                self.dist_tree.initDistStatic();
            },
            .dynamic => {
                @panic("TODO");
            },
        }

        var cursor = bl_start;
        while (cursor < bl_end) {
            if (self.tryFindMatch(cursor)) |match| {
                _ = match;
                @panic("TODO");
            }
            try self.lit_tree.writeSymbol(&self.bit_writer, self.sink, self.data[cursor]);
            cursor += 1;
        }
        // end of block
        try self.lit_tree.writeSymbol(&self.bit_writer, self.sink, 256);
    }

    fn compressWholeData(self: *Self) !void {
        var i: usize = 0;
        while (i < self.data.len) {
            const beg = i;
            i += FLATE_MAX_BLOCK_LEN;
            const is_final = i >= self.data.len;
            try self.compressBlock(beg, @min(i, self.data.len), is_final);
        }
        try self.bit_writer.flushByteAligned(self.sink);
    }
};


/// compresses data into flate stream
/// limitations: data should be fully read into memory
pub fn compress(data: []const u8, sink: *std.io.Writer, alloc: Alloc) !void {
    // const MIN_K = 3;
    // var i: usize = 0;
    // while (i < data.len) {
    //     var last_i: ?usize = null;
    //     var k: usize = MIN_K;
    //     const max_k = data.len-i;
    //     while (k <= max_k) : (k += 1) {
    //         const last_index = std.mem.lastIndexOf(u8, data[0..i+k-1], data[i..i+k]);
    //         if (last_index == null) break;
    //         last_i = last_index;
    //     }
    //     if (last_i != null) {
    //         try sink.print("[{}..][0..{}]\n", .{last_i.?, k});
    //         i += k;
    //     } else {
    //         try sink.print("'{}'\n", .{data[i]});
    //         i += 1;
    //     }
    // }
    // return 0;
    //
    var comp: Compressor = .init(alloc, sink, data);
    try comp.compressWholeData();
    
}
