const std = @import("std");
const azl = @import("azl");

fn print_usage() void {
    std.debug.print("usage: [dir_to_compress] [archive.zip]\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(alloc);
    _ = args.next().?;
    const dir_to_compress = args.next() orelse {
        print_usage();
        return error.InvalidArguments;
    };
    const archive_filename = args.next() orelse {
        print_usage();
        return error.InvalidArguments;
    };

    var dir = try std.Io.Dir.cwd().openDir(io, dir_to_compress, .{ .iterate = true });
    defer dir.close(io);

    var dir_iter = try dir.walk(alloc);
    defer dir_iter.deinit();

    const file = try std.Io.Dir.cwd().createFile(io, archive_filename, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);

    var zip_writer = try azl.ZipWriter.init(alloc, &writer.interface);
    defer zip_writer.deinit();

    while (try dir_iter.next(io)) |entry| {
        if (entry.kind != .file) {
            // TODO write directories?
            continue;
        }
        std.debug.print("compressing {s}\n", .{entry.path});

        const file_data = try entry.dir.readFileAlloc(io, entry.basename, alloc, .limited(1<<28));
        defer alloc.free(file_data);
        try zip_writer.addFile(file_data, .{ .filename = entry.path });
    }
    try zip_writer.finish();
}
