const std = @import("std");
const Alloc = std.mem.Allocator;

const flate = @import("flate.zig");

// lookback buf + block
const MAX_DATA_LEN: usize = flate.FLATE_MAX_LOOKBACK_DIST + flate.FLATE_MAX_BLOCK_LEN;

// Code adopted from
// https://cp-algorithms.com/string/suffix-array.html

pub const SuffixArrayBuilder = struct {
    buckets: []u32,
    positions1: []u32,
    positions2: []u32,
    classes1: []u32,
    classes2: []u32,

    pub fn init(alloc: Alloc) !@This() {
        const buckets = try alloc.alloc(u32, MAX_DATA_LEN+1);
        errdefer alloc.free(buckets);
        const positions1 = try alloc.alloc(u32, MAX_DATA_LEN+1);
        errdefer alloc.free(positions1);
        const positions2 = try alloc.alloc(u32, MAX_DATA_LEN+1);
        errdefer alloc.free(positions2);
        const classes1 = try alloc.alloc(u32, MAX_DATA_LEN+1);
        errdefer alloc.free(classes1);
        const classes2 = try alloc.alloc(u32, MAX_DATA_LEN+1);
        errdefer alloc.free(classes2);

        return .{
            .buckets = buckets,
            .positions1 = positions1,
            .positions2 = positions2,
            .classes1 = classes1,
            .classes2 = classes2,
        };
    }

    pub fn deinit(self: *@This(), alloc: Alloc) void {
        alloc.free(self.buckets);
        alloc.free(self.positions1);
        alloc.free(self.positions2);
        alloc.free(self.classes1);
        alloc.free(self.classes2);
        self.* = undefined;
    }

    // TODO use faster algorithm? (SA-IS?)

    /// Returns suffix array for data as a slice of iternal buffer
    pub fn constructSuffixArray(self: *@This(), data: []const u8) []const u32 {
        std.debug.assert(data.len <= MAX_DATA_LEN);

        const n: u32 = @intCast(data.len + 1);
        
        const ALPHABET_SIZE = 256;
        const b = self.buckets[0..@max(ALPHABET_SIZE, n)];

        const p1 = self.positions1[0..n];
        const p2 = self.positions2[0..n];

        if (data.len < 2) {
            p1[0] = 0;
            return p1[0..data.len];
        }

        var c1 = self.classes1[0..n];
        var c2 = self.classes2[0..n];

        @memset(b[0..ALPHABET_SIZE], 0);

        for (data) |el| {
            b[el] += 1;
        }
        b[0] += 1;
        for (1..ALPHABET_SIZE) |i| {
            b[i] += b[i-1];
        }
        for (0..data.len) |i| {
            b[data[i]] -= 1;
            p1[b[data[i]]] = @intCast(i);
        }
        p1[0] = n-1;
        c1[p1[0]] = 0;
        var classes_count: u32 = 1;
        c1[p1[1]] = 1;
        for (2..n) |i| {
            if (data[p1[i]] != data[p1[i-1]]) {
                classes_count += 1;
            }
            c1[p1[i]] = classes_count;
        }
        classes_count += 1;

        var h: u32 = 1;
        while (true) : (h <<= 1) {
            for (0..n) |i| {
                p2[i] = wrapBy(p1[i] + n - h, n);
            }
            @memset(b[0..classes_count], 0);
            
            for (0..n) |i| {
                b[c1[p2[i]]] += 1;
            }
            for (1..classes_count) |i| {
                b[i] += b[i-1];
            }
            for (0..n) |i| {
                const j = n - 1 - i;
                b[c1[p2[j]]] -= 1;
                p1[b[c1[p2[j]]]] = p2[j];
            }

            if (h << 1 >= n) {
                break;
            }

            c2[p1[0]] = 0;
            classes_count = 0;
            for (1..n) |i| {
                if (c1[p1[i]] != c1[p1[i-1]] or c1[wrapBy(p1[i] + h, n)] != c1[wrapBy(p1[i-1] + h, n)]) {
                    classes_count += 1;
                }
                c2[p1[i]] = classes_count;
            }
            classes_count += 1;
            std.mem.swap([]u32, &c1, &c2);
        }

        return p1[1..n];
    }

    fn wrapBy(num: u32, n: u32) u32 {
        if (num >= n) 
            return num - n;
        return num;
    }

    pub fn constructLcp(self: *@This(), data: []const u8, sa: []const u32) []const u32 {
        std.debug.assert(data.len == sa.len);
        const n = data.len;
        const rank = self.buckets[0..n];
        for (0..n) |i| {
            rank[sa[i]] = @intCast(i);
        }

        var k: u32 = 0;
        const lcp = self.classes1[0..n-1];
        for (0..n) |i| {
            if (rank[i] == n - 1) {
                k = 0;
                continue;
            }
            const j = sa[rank[i] + 1];
            while (i + k < n and j + k < n and data[i+k] == data[j+k]) {
                k += 1;
            }
            lcp[rank[i]] = k;
            if (k > 0) k -= 1;
        }

        return lcp;
    }

    pub fn constructRevSa(self: *@This(), sa: []const u32) []const u32 {
        const rev_sa = self.classes2[0..sa.len];
        for (0..sa.len) |i| {
            rev_sa[sa[i]] = @intCast(i);
        }
        return rev_sa;
    }
};
