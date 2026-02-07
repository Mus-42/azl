const std = @import("std");
const bit_io = @import("bit_io.zig");

pub fn Huffman(comptime max_symbols: usize, comptime max_code_bits: u4, comptime decoder_lookup_bits: u4) type {
    std.debug.assert(max_symbols > 0);
    std.debug.assert(max_symbols <= (1 << max_code_bits));

    return struct {
        pub const Code = std.meta.Int(.unsigned, max_code_bits);
        const symbol_bits = std.math.log2_int_ceil(usize, max_symbols);
        pub const Symbol = std.meta.Int(.unsigned, symbol_bits);

        pub const TreeBuilder = struct {
            // symbol -> code
            codes: [max_symbols]Code = @splat(0),
            // symbol -> len
            lengths: [max_symbols]u4 = @splat(0),
            // len -> count
            length_counts: [@as(usize, max_code_bits) + 1]Symbol = @splat(0),

            const Self = @This();

            pub fn initLen(lengths: []const u4) !Self {
                std.debug.assert(lengths.len <= max_symbols);

                var self: Self = .{};
                @memcpy(self.lengths[0..lengths.len], lengths);
                for (lengths) |len| {
                    self.length_counts[len] += 1;
                }
                self.length_counts[0] += @intCast(max_symbols - lengths.len);
                // invalid lenghts where provided
                if (!self.isCodeConstructionPossible()) 
                    return error.ImpossibleHuffmanCodeConstruction;
                self.computeCodesFromSymbolLengths();
                return self;
            }


            pub fn initFreq(freq: []const u16) Self {
                std.debug.assert(freq.len <= max_symbols);

                var self: Self = .{};
                self.computeLenFromFreq(freq);
                if (!self.isCodeConstructionPossible()) {
                    // should be unreacheble
                    // TODO more testing to remove that
                    @panic("Unexpected imposible huffman code lenghts from computeLenFromFreq");
                }
                self.computeCodesFromSymbolLengths();
                return self;
            }

            const PackageMergeInput = struct {
                sym: Symbol,
                freq: u16,

                fn lessThan(_: void, a: PackageMergeInput, b: PackageMergeInput) bool {
                    return a.freq < b.freq;
                }
            };

            fn computeLenFromFreq(self: *Self, freq: []const u16) void {
                var input: [max_symbols]PackageMergeInput = undefined;
                var input_used: usize = 0;

                for (0.., freq) |sym, f| {
                    if (f != 0) {
                        input[input_used] = .{ .sym = @intCast(sym), .freq = f };
                        input_used += 1;
                    }
                }

                if (input_used <= 2) {
                    for (0..input_used) |i| {
                        const sym = input[i].sym;
                        self.lengths[sym] = 1;
                        self.length_counts[1] += 1;
                    }
                    return;
                }

                // order by freq
                std.sort.pdq(PackageMergeInput, input[0..input_used], {}, PackageMergeInput.lessThan);

                self.pakageMergeCompuleLen(input[0..input_used]);
            }

            fn pakageMergeCompuleLen(self: *Self, input: []const PackageMergeInput) void {
                std.debug.assert(2 < input.len and input.len <= max_symbols);

                // cost for each package
                var packages: [2][max_symbols]u32 = undefined;
                // [i][j] how many symbols where used at iteration [i] while constructing packages up to [j]
                var syms_used: [max_code_bits][max_symbols]u16 = undefined;

                const n = input.len;
                const max_bits: u4 = @intCast(@min(max_code_bits, n));

                var packages_curr = &packages[0];
                var packages_prev = &packages[1];
                var packages_count = n / 2;

                for (0..packages_count) |i| {
                    packages_curr[i] = @as(u32, input[i*2].freq) + @as(u32, input[i*2+1].freq);
                }

                for (1..max_bits) |bits| {
                    const t = packages_curr;
                    packages_curr = packages_prev;
                    packages_prev = t;
                    @memset(packages_curr, 0);

                    var input_i: usize = 0;
                    var pkg_i: usize = 0;
                    const new_packages_count = (packages_count + input.len) / 2;

                    // "merge" previous package and input (into sorted seq) then combine into new package
                    for (0..2*new_packages_count) |i| {
                        if (input_i < n and input[input_i].freq <= packages_prev[pkg_i]) {
                            packages_curr[i/2] += input[input_i].freq;
                            input_i += 1;
                        } else {
                            packages_curr[i/2] += packages_prev[pkg_i];
                            pkg_i += 1;
                        }
                        syms_used[bits][i/2] = @intCast(input_i);
                    }

                    packages_count = new_packages_count;
                }

                // walk back and recompute length
                var lengths: [max_symbols]u16 = @splat(0);
                var packages_used = n - 1;
                std.debug.assert(packages_count >= packages_used);
                var bits = max_bits;
                while (bits > 1) {
                    bits -= 1;
                    const syms = syms_used[bits][packages_used-1];
                    // use first "syms" symbols: 0..syms-1
                    if (syms > 0) {
                        lengths[syms-1] += 1;
                    }
                    packages_used = packages_used * 2 - syms;
                    if (packages_used == 0) break;
                }
                if (packages_used != 0) {
                    // on first iteration 1 package = eactly 2 symbols
                    lengths[packages_used*2-1] += 1;
                }
                // recompute how many times every symbol was used
                var i = n-1;
                while (i > 0) {
                    i -= 1;
                    lengths[i] += lengths[i+1];
                }
                // uses count == symbol lenght
                for (lengths[0..n], input) |len, sym| {
                    self.lengths[sym.sym] = @intCast(len);
                    self.length_counts[len] += 1;
                }
            }

            fn isCodeConstructionPossible(self: *const Self) bool {
                var available_nodes: u32 = 1;
                for (self.length_counts[1..]) |cnt| {
                    available_nodes <<= 1;
                    if (available_nodes < cnt)
                        return false;
                    available_nodes -= cnt;
                }
                return true;
            }

            fn computeCodesFromSymbolLengths(self: *Self) void {
                var code: u16 = 0;
                var next_code: [max_code_bits]u16 = @splat(0);
                for (1..max_code_bits) |bits| {
                    code += self.length_counts[bits];
                    code <<= 1;
                    next_code[bits] = code;
                }

                for (0..max_symbols) |sym| {
                    const code_len = self.lengths[sym];
                    if (code_len == 0)
                        continue;
                    self.codes[sym] = @intCast(next_code[code_len - 1]);
                    next_code[code_len - 1] += 1;
                }
            }

            pub fn debugDump(self: *const Self) void {
                for (0..max_symbols) |i| {
                    if (self.lengths[i] > 0) {
                        std.debug.print("{d:03} {b:0>[2]}\n", .{i, self.codes[i], self.lengths[i]});
                    }
                }
            }

        };

        const STATIC_CODES_TREE = blk: {
            var tree: TreeBuilder = .{};

            if (max_symbols == 286) {
                // static lit codes
                for (0..max_symbols) |i| {
                    const len = if (i < 144) 8
                        else if (i < 256) 9
                        else if (i < 280) 7
                        else 8;
                    tree.lengths[i] = len;
                    tree.length_counts[len] += 1;
                }
                // Symbols 286-287 (len 8) participate in code consturction but not present in actual tree
                tree.length_counts[8] += 2;
                tree.computeCodesFromSymbolLengths();
                tree.length_counts[8] -= 2;
            } else if (max_symbols == 30) {
                // stasic dist codes
                for (0..max_symbols) |i| {
                    const len = 5;
                    tree.lengths[i] = len;
                    tree.length_counts[len] += 1;
                }
                tree.computeCodesFromSymbolLengths();
            } else {
                //break :blk null;
                @compileError("Unsupported");
            }

            break :blk tree;
        };

        pub const Decoder = struct {
            const Self = @This();

            syms: [max_symbols]SymNode,
            // first decoder_lookup_bits -> index into syms
            lookup: [1 << decoder_lookup_bits]Symbol,

            const SymNode = packed struct {
                mcode: Code,
                code_len: u4,
                sym: Symbol,


                fn lessThan(_: void, a: SymNode, b: SymNode) bool {
                    return a.mcode < b.mcode;
                }
            };

            pub fn initLen(lenghts: []const u4) !Self {
                std.debug.assert(lenghts.len <= max_symbols);

                const tree = try TreeBuilder.initLen(lenghts);
                var self: Self = undefined;
                self.buildFrom(&tree);
                return self;
            }

            pub fn initStatic() Self {
                var self: Self = undefined;
                self.buildFrom(&STATIC_CODES_TREE);
                return self;
            }

            fn buildFrom(self: *Self, tree: *const TreeBuilder) void {
                for (0..max_symbols, &self.syms) |i, *sym| {
                    sym.code_len = tree.lengths[i];
                    sym.sym = @intCast(i);
                    if (sym.code_len > 0) {
                        const fill = max_code_bits - tree.lengths[i];
                        sym.mcode = tree.codes[i] << @intCast(fill) | @as(Code, @intCast((@as(u16, 1) << fill) - 1));
                    }
                }
                std.sort.pdq(SymNode, &self.syms, {}, SymNode.lessThan);
                var lookup_cur: usize = 0;
                for (0.., &self.syms) |i, sym| {
                    if (sym.code_len == 0) continue;
                    const lookup_i = (sym.mcode) >> (max_code_bits - decoder_lookup_bits);
                    while (lookup_cur <= lookup_i) : (lookup_cur += 1) {
                        self.lookup[lookup_cur] = @intCast(i);
                    }
                }
                while (lookup_cur < self.lookup.len) : (lookup_cur += 1) {
                    self.lookup[lookup_cur] = std.math.maxInt(Symbol);
                }
            }

            pub fn debugDump(self: *const Self) void {
                for (&self.syms) |sym| {
                    if (sym.code_len > 0) {
                        std.debug.print("{d:03} {b:0>[2]}\n", .{sym.sym, sym.mcode, max_code_bits});
                    }
                }
            }

            pub fn readSymbol(self: *const Self, bit_reader: *bit_io.BitReader, input: *std.Io.Reader) !Symbol {
                const rcode_bits = try bit_reader.peekBits(input, max_code_bits);
                const code = @bitReverse(@as(Code, @intCast(rcode_bits)));
                const sym_index = try self.lookupSymIndex(code);
                bit_reader.tossBits(input, @intCast(self.syms[sym_index].code_len));
                return self.syms[sym_index].sym;
            }

            pub fn lookupSymIndex(self: *const Self, code: Code) !usize {
                const MASKS = comptime blk: {
                    var masks: [max_code_bits]Code = undefined;
                    for (0..max_code_bits) |i| {
                        const bits = i + 1;
                        masks[i] = @intCast(((@as(u16, 1) << bits) - 1) << (max_code_bits - bits));
                    }
                    break :blk masks;
                };

                var i: usize = self.lookup[code >> (max_code_bits - decoder_lookup_bits)];
                while (i < max_symbols) : (i += 1) {
                    const sym = self.syms[i];
                    if (sym.code_len == 0) continue;
                    const mask = MASKS[sym.code_len-1];
                    if ((code ^ sym.mcode) & mask == 0) {
                        return i;
                    }
                    if (code < sym.mcode & mask) break;
                }
                return error.InvalidHuffmanCode;
            }
        };

        pub const Encoder = struct {
            const Self = @This();
            
            // symbol -> bit-reversed code
            rcode: [max_symbols]Code,
            // TODO pack them together
            lengths: [max_symbols]u4,

            pub fn initFreq(freq: []const u16) Self {
                std.debug.assert(freq.len <= max_symbols);

                const tree = TreeBuilder.initFreq(freq);
                var self: Self = undefined;
                self.buildFrom(&tree);
                return self;
            }

            pub fn initStatic() Self {
                var self: Self = undefined;
                self.buildFrom(&STATIC_CODES_TREE);
                return self;
            }

            fn buildFrom(self: *Self, tree: *const TreeBuilder) void {
                @memcpy(&self.lengths, &tree.lengths);
                
                for (0..max_symbols) |sym| {
                    const code = tree.codes[sym];
                    const code_len = self.lengths[sym];
                    if (code_len == 0) continue;
                    self.rcode[sym] = @bitReverse(code) >> @intCast(max_code_bits - code_len);
                }
            }

            pub fn writeSymbol(self: *Self, bit_writer: *bit_io.BitWriter, sink: *std.Io.Writer, symbol: Symbol) !void {
                if (symbol >= max_symbols or self.lengths[symbol] == 0) {
                    @branchHint(.cold);
                    return error.InvalidHuffmanTreeSymbol;
                }
                try bit_writer.writeBits(sink, self.rcode[symbol], self.lengths[symbol]);
            }
        };
    };
}
