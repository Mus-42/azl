const std = @import("std");

pub const FLATE_BUF_LEN = 32 * 1024;
pub const HUFFMAN_TREE_MAX_LEN = 288;
pub const MAX_CODE_BITS = 15;

const LEN_SYM_EXTRA_BITS: [30]u4 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 0 };
const LEN_SYM_OFFSETS: [30]u16 = .{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258, 0 };


const DIST_SYM_EXTRA_BITS: [30]u4 =.{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const DIST_SYM_OFFSETS: [30]u16 = .{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };


const HuffmanTree = struct {
    nodes: [HUFFMAN_TREE_MAX_LEN]TreeNode = undefined,
    len_counts: [MAX_CODE_BITS]u15 = undefined,
    len_lookup: [MAX_CODE_BITS]u16 = undefined,

    const TreeNode = packed struct {
        code: u15 = 0,
        // 0 means not used
        code_len: u4 = 0,
        symbol: u9 = 0,
    };
    
    const Self = @This();

    fn loadStatic(self: *Self) void {
        self.clear();
        for (0.., &self.nodes) |i, *node| {
            node.symbol = @intCast(i);
            if (i < 144) { node.code_len = 8; }
            else if (i < 256) { node.code_len = 9; }
            else if (i < 280) { node.code_len = 7; }
            else { node.code_len = 8; }
        }

        self.rebuildCodes();
        self.rebuildLenLookup();
    }

    fn debugDump(self: *Self) void {
        for (&self.nodes) |node| {
            if (node.code_len > 0) {
                std.debug.print("{d:03} {b:0>[2]}\n", .{node.symbol, node.code, node.code_len});
            }
        }
    }

    fn clear(self: *Self) void {
        @memset(&self.nodes, .{});
    }

    fn rebuildCodes(self: *Self) void {
        var next_code: [MAX_CODE_BITS]u15 = @splat(0);
        self.len_counts = @splat(0);

        for (&self.nodes) |node| {
            if (node.code_len > 0) {
                self.len_counts[node.code_len - 1] += 1;
            }
        }

        var code: u15 = 0;
        for (0..MAX_CODE_BITS) |bits| {
            if (bits > 0) code += self.len_counts[bits-1];
            code <<= 1;
            next_code[bits] = code;
        }

        for (&self.nodes) |*node| {
            if (node.code_len == 0)
                continue;
            node.code = next_code[node.code_len - 1];
            next_code[node.code_len - 1] += 1;
        }
    }

    fn nodeLenLookupLessThanCmp(_: void, a: TreeNode, b: TreeNode) bool {
        if (a.code_len != b.code_len) {
            return a.code_len < b.code_len;
        }
        return a.code < b.code;
    }

    fn rebuildLenLookup(self: *Self) void {
        std.mem.sort(TreeNode, &self.nodes, {}, nodeLenLookupLessThanCmp);
        var i: u16 = 0;
        while (i < self.nodes.len and self.nodes[i].code_len == 0) {
            i += 1;
        }

        for (0..MAX_CODE_BITS) |bits| {
            self.len_lookup[bits] = i;
            i += self.len_counts[bits];
        }

        std.debug.assert(i == self.nodes.len);
    }

    fn lookUpSymbolByCode(self: *const Self, code: u16, code_len: u4) ?u15 {
        std.debug.assert(code_len > 0);

        const len = self.len_counts[code_len - 1];
        if (len == 0)
            return null;

        // for (&self.nodes) |node| {
        //     if (node.code_len == code_len and node.code == code)
        //         return node.symbol;
        // }

        // return null;

        const i = self.len_lookup[code_len - 1];
        const i_code = self.nodes[i].code;
        if (i_code > code)
            return null;

        const offset = code - i_code;
        if (offset >= len)
            return null;

        std.debug.assert(self.nodes[i + offset].code == code);
        return self.nodes[i + offset].symbol;
    }
};

pub const Decompressor = struct {
    reader: std.Io.Reader,
    input: *std.Io.Reader,
    buf: []u8,
    bit_capacity: u8,
    huffman_tree: HuffmanTree = .{},
    state: State = .reading,

    const Self = @This();

    const State = enum {
        reading,
        ended,
    };

    pub fn init(input: *std.Io.Reader, buf: []u8) Self {
        std.debug.assert(buf.len >= FLATE_BUF_LEN);
        std.debug.assert(input.buffer.len > 0);

        return .{
            .reader = .{
                .vtable = &.{
                    .stream = streamImpl,
                },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
            .input = input,
            .buf = buf,
            .bit_capacity = 0,
        };
    }

    fn byteAlign(self: *Self) void {
        if (self.bit_capacity != 0) {
            self.input.toss(1);
            self.bit_capacity = 0;
        }
    }

    fn readBit(self: *Self) !u1 {
        const first_byte = try self.input.peekByte();
        std.debug.assert(self.bit_capacity < 8);
        //const bit: u1 = @intCast(first_byte >> @intCast(7 - self.bit_capacity) & 1);
        const bit: u1 = @intCast(first_byte >> @intCast(self.bit_capacity) & 1);
        self.bit_capacity += 1;
        if (self.bit_capacity >= 8) {
            self.bit_capacity = 0;
            self.input.toss(1);
        }
        return bit;
    }

    fn readUint(self: *Self, bits: u4) !u16 {
        var v: u16 = 0;
            
        // inefficient for big numbers but we don't realy need any so it's fine
        for (0..bits) |i| {
            //v <<= 1;
            //v |= try self.readBit();
            v |= @as(u8, try self.readBit()) << @intCast(i);
        }

        return v;
    }

    fn readHuffmanTree(self: *Self) !void { 
        const literal_len_codes = @as(usize, try self.readUint(5)) + 257;
        const hdist = try self.readUint(5);
        const len_codes_count = @as(usize, try self.readUint(4)) + 4;

        std.debug.print("{}\n", .{len_codes_count});

        // lengths alphabet
        const LEN_ORDER: [19]u8 = .{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

        self.huffman_tree.clear();
        for (0..len_codes_count) |i| {
            const len = try self.readUint(3);
            self.huffman_tree.nodes[i].symbol = LEN_ORDER[i];
            self.huffman_tree.nodes[i].code_len = @intCast(len);
        }
        self.huffman_tree.rebuildCodes();
        self.huffman_tree.rebuildLenLookup();

        self.huffman_tree.debugDump();

        // lenghts for acutal deflate alphabet
        var len_codes: [HUFFMAN_TREE_MAX_LEN]u4 = @splat(0);
        var i: usize = 0;
        std.debug.print("{}\n", .{literal_len_codes});
        while (i < literal_len_codes) {
            const len_sym = try self.readHuffmanCodeSymbol();
            std.debug.print("{}:  len sym = {}\n", .{i, len_sym});
            if (len_sym < 16) {
                len_codes[i] = @intCast(len_sym);
                i += 1;
                continue;
            }

            if (len_sym > 18) {
                return error.ReadFailed;
            }

            var num: usize = 0;
            var val: u4 = 0;
            if (len_sym == 16) {
                if (i == 0) return error.ReadFailed;
                num = @as(usize, try self.readUint(2)) + 3;
                val = len_codes[i-1];
            } else if (len_sym == 17) {
                num = @as(usize, try self.readUint(3)) + 3;
            } else if (len_sym == 18) {
                num = @as(usize, try self.readUint(7)) + 11;
            }

            for (0..num) |_| {
                if (i == HUFFMAN_TREE_MAX_LEN) 
                    return error.ReadFailed;
                len_codes[i] = val;
                i += 1;
            }
        }

        std.debug.print("{}\n", .{hdist});

        @panic("TODO read huffman tree");
    }

    fn readHuffmanCodeSymbol(self: *Self) !u15 {
        var code: u15 = 0;
        for (0..15) |code_len| {
            code <<= 1;
            code |= try self.readBit();
            //code |= @as(u15, try self.readBit()) << @intCast(code_len);
            if (self.huffman_tree.lookUpSymbolByCode(code, @intCast(code_len + 1))) |symbol|
                return symbol;
        }
        std.debug.print("failed code: {b:015}\n", .{code});
        return error.ReadFailed;
    }

    const IternalBufWriter = struct {
        reader: *Self,
        interface: std.io.Writer,
    };

    fn iternalWriterDrain(w: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
        const buf_writer: *IternalBufWriter = @fieldParentPtr("interface", w);
        // TODO
    }

    fn iternalBufWriter(self: *Self) IternalBufWriter {
        // TODO
        //
        return .{
            .reader = self,
            .interface = .{
                .buffer = &.{},
                .end = 0,
                .vtable = &.{
                    .drain = iternalWriterDrain,
                },
            },
        };
    }

    fn streamImpl(r: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) std.io.Reader.StreamError!usize {
        std.debug.assert(limit == .unlimited);

        const self: *Self = @fieldParentPtr("reader", r);

        if (self.state == .ended) {
            return error.EndOfStream;
        }

        //while (true) {
        //    const b = try self.readBit();
        //    std.debug.print("{}", .{b});
        //}

        defer std.debug.print("\n", .{});
    
        const isFinal = try self.readBit() != 0;
        const blockType = self.readUint(2) catch return error.ReadFailed;
 
        if (isFinal) 
            self.state = .ended;

        std.debug.print("isFinal: {}, type {b:02}\n", .{isFinal, blockType});

        if (blockType == 0) {
            self.byteAlign();
            const len = self.input.takeInt(u16, .little) catch return error.ReadFailed;
            const nlen = self.input.takeInt(u16, .little) catch return error.ReadFailed;
            std.debug.print("{} {}\n", .{len, nlen});
            // TODO
            if (len ^ nlen != 0xFFFF)
                return error.ReadFailed;
            // TODO
            self.input.streamExact(w, len) catch return error.ReadFailed;
            return len;
        }

        if (blockType == 0b01) {
            self.huffman_tree.loadStatic();
            self.huffman_tree.debugDump();
        } else {
            self.readHuffmanTree() catch return error.ReadFailed;
        }

        while (true) {
            //const symbol = try self.readBit();
            const sym = try self.readHuffmanCodeSymbol();
            std.debug.print("SYM: {}\n", .{sym});
            if (sym < 256) {
                // TODO
                continue;
            }
            if (sym == 256)
                break;
         
            const len_extra = try self.readUint(LEN_SYM_EXTRA_BITS[sym - 257]) + LEN_SYM_OFFSETS[sym - 257];
            const dist_code = try self.readUint(5);
            const dist = try self.readUint(DIST_SYM_EXTRA_BITS[dist_code]) + DIST_SYM_OFFSETS[dist_code];

            std.debug.print("len={} dist={}\n", .{len_extra, dist});
        }

        //return self.reader.stream(w, limit);
        return 0;
    }
};
