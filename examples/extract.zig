const std = @import("std");
const azl = @import("azl");

fn print_usage() void {
    std.debug.print("usage: [extract_dir] [archive.zip]", .{});
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.next().?;
    const extract_dir = args.next() orelse {
        print_usage();
        return error.InvalidArguments;
    };
    const archive_filename = args.next() orelse {
        print_usage();
        return error.InvalidArguments;
    };

    std.fs.cwd().makeDir(extract_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var out_dir = try std.fs.cwd().openDir(extract_dir, .{});
    defer out_dir.close();

    const file = try std.fs.cwd().openFile(archive_filename, .{});
    defer file.close();

    const stream = file.seekableStream();
    var iter = try azl.ZipReader(@TypeOf(stream)).init(stream);
    defer iter.deinit();


    while (try iter.next()) |entry| {
        std.debug.print("extracting {s}\n", .{entry.name});
        if (entry.isDirectory()) {
            try out_dir.makePath(entry.name[0 .. entry.name.len - 1]);
            continue;
        }

        if (std.fs.path.dirname(entry.name)) |dirname| {
            try out_dir.makePath(dirname);
        }

        const entry_out = try out_dir.createFile(entry.name, .{});
        defer entry_out.close();
        try iter.extractFile(entry, entry_out.writer());
    }
}
