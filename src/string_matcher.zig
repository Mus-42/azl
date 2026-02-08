const std = @import("std");
const flate = @import("flate.zig");

const BUCKET_BITS = 12;

// TODO make it faster and set FLATE_MAX_LOOKBACK_DIST as a limit
const RING_SIZE: u32 = 8 * 1024; // flate.FLATE_MAX_LOOKBACK_DIST;
const HASH_SHIFT = 32 - BUCKET_BITS;
const HASH_PRIME: u32 = 0xa4242453;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(RING_SIZE));
}

pub const MatchPreset = enum {
    fast,
    good,
};

pub const MatchLimits = struct {
    // soft limits on dist/lenght
    good_enough_match_dist: u16,
    good_enough_match_len: u16,
    // hard limit on steps
    max_chain_steps: u16,

    pub fn fromPreset(p: MatchPreset) MatchLimits {
        return switch (p) {
            .fast => .{ 
                .good_enough_match_dist = 4096, 
                .good_enough_match_len = 128, 
                .max_chain_steps = 8,
            },
            .good => .{
                .good_enough_match_dist = RING_SIZE, 
                .good_enough_match_len = 256, 
                .max_chain_steps = 32,
            },
        };
    }
};


// TODO make RING_SIZE & BUCKET_BITS configurable at runtime (select from MatchLimits)?

pub const StringMatcher = struct {
    match_limits: MatchLimits,
    data: []const u8,
    head_position: usize = 0,
    buckets: [1<<BUCKET_BITS]u16 = @splat(0),
    ring: [RING_SIZE]u16 = @splat(0),

    const Self = @This();

    pub fn seekTo(self: *Self, new_head_position: usize) void {
        std.debug.assert(new_head_position <= self.data.len);
        if (new_head_position < self.head_position) {
            self.reset();
            // TODO smaller size if possible
            self.head_position = new_head_position -| RING_SIZE;
        }
        while (self.head_position < new_head_position) {
            self.advanceHead();
        }
    }

    fn reset(self: *Self) void {
        // we don't care that much??? or is it better to fill everything just in case?
        _ = self;
    }

    fn bucketHash(num: u32) u32 {
        return (num *% HASH_PRIME) >> HASH_SHIFT;
    }

    fn hashAt(self: *const Self, pos: usize) ?u32 {
        std.debug.assert(pos <= self.data.len);
        const rem = self.data[pos..];
        if (rem.len < 4) return null;
        return bucketHash(@bitCast(rem[0..4].*));
    }

    fn advanceHead(self: *Self) void {
        @setRuntimeSafety(false); // Too slow in debug

        const head = self.head_position;
        if (self.head_position < self.data.len) 
            self.head_position += 1;
        const bucket_idx = self.hashAt(head) orelse return;
        const new_pos: u16 = @intCast(head & (RING_SIZE - 1));
        const old_pos = self.buckets[bucket_idx];
        self.buckets[bucket_idx] = new_pos;
        self.ring[new_pos] = old_pos;
    }
    
    pub const Match = struct {
        len: u16,
        dist: u16,
    };
    
    pub fn findLongestMatch(self: *const Self, max_len: usize) ?Match {
        // @setRuntimeSafety(false); // Too slow in debug

        const d = self.data;
        const head = self.head_position;
        const bucket_idx = self.hashAt(head) orelse return null;
        var best_len: u16 = 0;
        var best_dist: u16 = 0;
        var pos = self.buckets[bucket_idx];
        var prev_start = head;
        var steps_taken: usize = 0;
        while (true) : (pos = self.ring[pos]) {
            if (steps_taken >= self.match_limits.max_chain_steps) break;
            steps_taken += 1;

            const dist: u16 = @intCast((head -% pos) & (RING_SIZE - 1));
            if (dist == 0 or dist > head) break; // chain is broken
            const start = head - dist;

            if (prev_start <= start) break; // chain is broken
            prev_start = start;
            if (self.hashAt(start) != bucket_idx) break; // chain is broken

            var len: u16 = 0;
            const real_max_len = @min(@min(max_len, d.len - head), flate.FLATE_MAX_LOOKBACK_LEN);
            while (len < real_max_len and d[start+len] == d[head+len]) {
                len += 1;
            }

            if (len > best_len and len >= flate.FLATE_MIN_LOOKBACK_LEN) {
                best_dist = dist;
                best_len = len;

                // soft limits
                if (dist >= self.match_limits.good_enough_match_dist or len > self.match_limits.good_enough_match_len) {
                    break;
                }
            }
        }

        if (best_len == 0) return null;
        return .{ .len = best_len, .dist = best_dist };
    }
};

