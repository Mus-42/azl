const std = @import("std");
const azl = @import("azl");

fn print_usage() void {
    std.debug.print("usage: [extract_dir] [archive.zip]\n", .{});
}

var buf2: [32768 * 4]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(alloc);
    _ = args.next().?;
    const extract_dir = args.next() orelse {
        print_usage();
        return error.InvalidArguments;
    };

    const archive_filename = args.next() orelse {
        print_usage();
        return error.InvalidArguments;
    };

    std.Io.Dir.cwd().createDir(io, extract_dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var out_dir = try std.Io.Dir.cwd().openDir(io, extract_dir, .{});
    defer out_dir.close(io);

    const file = try std.Io.Dir.cwd().openFile(io, archive_filename, .{});
    defer file.close(io);
    
    // TODO
    var buf: [8192]u8 = undefined;
    var reader = file.reader(io, &buf);
    var iter = try azl.zipReader(&reader);

    while (try iter.next()) |entry| {
        std.debug.print("extracting {s}\n", .{entry.name});
        if (entry.isDirectory()) {
            try out_dir.createDirPath(io, entry.name[0 .. entry.name.len - 1]);
            continue;
        }

        if (std.fs.path.dirname(entry.name)) |dirname| {
            try out_dir.createDirPath(io, dirname);
        }

        const entry_out = try out_dir.createFile(io, entry.name, .{});
        defer entry_out.close(io);
        var writer = entry_out.writer(io, &buf2);
        try iter.extractFile(entry, &writer.interface);
        try writer.end();
    }
}
