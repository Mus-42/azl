const std = @import("std");
const azl = @import("azl");

fn print_usage() void {
    std.debug.print("usage: [dir_to_compress] [archive.zip]", .{});
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.next().?;
    const dir_to_compress = args.next() orelse {
        print_usage();
        return error.InvalidArguments;
    };
    const archive_filename = args.next() orelse {
        print_usage();
        return error.InvalidArguments;
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var dir = try std.fs.cwd().openDir(dir_to_compress, .{ .iterate = true });
    defer dir.close();

    var dir_iter = try dir.walk(alloc);
    defer dir_iter.deinit();

    const file = try std.fs.cwd().createFile(archive_filename, .{});
    defer file.close();

    var buf_writer = std.io.bufferedWriter(file.writer());
    var zip_writer = try azl.ZipWriter(@TypeOf(buf_writer.writer())).init(alloc, buf_writer.writer());
    defer zip_writer.deinit();

    while (try dir_iter.next()) |entry| {
        if (entry.kind != .file) {
            // TODO write directories?
            continue;
        }

        std.debug.print("compressing {s}\n", .{entry.path});

        const file_data = try entry.dir.readFileAlloc(alloc, entry.basename, 1<<28);
        defer alloc.free(file_data);
        try zip_writer.addFile(file_data, .{ .filename = entry.path });
    }
    try zip_writer.finish();
    try buf_writer.flush();
}
