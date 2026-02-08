const std = @import("std");
pub const flate = @import("flate.zig");
const Alloc = std.mem.Allocator;

test {
    _ = flate;
}

pub const CompressionMethod = enum(u16) {
    none    = 0,
    deflate = 8,
    _
};

pub const Signature = enum(u32) {
    local_file_header             = 0x04034b50,
    central_directory_file_header = 0x02014b50,
    digital_signature             = 0x05054b50,
    end_of_central_directory      = 0x06054b50,
    _
};

pub const Version = extern struct {
    zip_version: u8,
    made_by: u8,
};

const AZL_ZIP_VESION: Version = .{ .zip_version = 20, .made_by = 0 };

pub const LocalFileHeader = extern struct {
    version_required: Version,
    flags: u16 align(1),
    compression: CompressionMethod align(1),
    last_modified_time: u16 align(1),
    last_modified_date: u16 align(1),
    crc_32: u32 align(1),
    compressed_size: u32 align(1),
    uncompressed_size: u32 align(1),
    file_name_length: u16 align(1),
    extra_field_length: u16 align(1),
};

pub const CentralDirectoryFileHeader = extern struct {
    version_required: Version,
    version_created: Version,
    flags: u16 align(1),
    compression_method: CompressionMethod align(1),
    last_modified_time: u16 align(1),
    last_modified_date: u16 align(1),
    crc_32: u32 align(1),
    compressed_size: u32 align(1),
    uncompressed_size: u32 align(1),
    file_name_length: u16 align(1),
    extra_field_length: u16 align(1),
    file_comment_length: u16 align(1),
    disk_number_start: u16 align(1),
    internal_file_attributes: u16 align(1),
    external_file_attributes: u32 align(1),
    relative_offset_of_local_header: u32 align(1),
};

pub const EndOfCentralDirectory = extern struct {
    this_disk_num: u16 align(1),
    cd_start_disk_num: u16 align(1),
    this_disk_entries: u16 align(1),
    total_cd_entries: u16 align(1),
    cd_size: u32 align(1),
    cd_offset: u32 align(1),
    file_comment_length: u16 align(1),
};

fn readEndOfCentralDirectory(stream: anytype) !EndOfCentralDirectory {
    // TODO here should be some smart search logic instead?
    const stream_len = try stream.getSize();
    const cd_end_len = @sizeOf(EndOfCentralDirectory) + 4;
    if (stream_len < cd_end_len) 
        return error.ZipNoCentralDirectory;
    try stream.seekTo(stream_len - cd_end_len);

    const reader = &stream.interface;
    try reader.fill(cd_end_len);
    const signature: Signature = @enumFromInt(try reader.takeInt(u32, .little));
    if (signature != .end_of_central_directory) 
        return error.ZipNoCentralDirectory;
    const cd_end = try reader.takeStruct(EndOfCentralDirectory, .little);

    // sanity checks (verify some assumptions that library make about file)
    if (cd_end.this_disk_num != 0)
        return error.ZipMultidiskUnsupported;
    if (cd_end.cd_start_disk_num != 0) 
        return error.ZipMultidiskUnsupported;
    if (cd_end.this_disk_entries != cd_end.total_cd_entries) 
        return error.ZipMultidiskUnsupported;
    if (cd_end.cd_offset + cd_end.cd_size + cd_end_len != stream_len)
        return error.ZipInvalidCDSize;
    return cd_end;
}

const ZIP_MAX_FILENAME_LEN = 256;

// TODO make seekableStream an easy implementable interface???
// for now it just assumes that stream has .interface: Reader member and 
// methods like seekTo and logicalPos

pub fn ZipReader(comptime SeekableStream: type) type {
    return struct {
        stream: SeekableStream,
        cd_entries: u16,
        cd_entry_current: u16 = 0,
        name_buf: [ZIP_MAX_FILENAME_LEN]u8 = undefined,

        pub const Entry = struct {
            name: []u8,
            compressed_size: u32,
            uncompressed_size: u32,
            compression_method: CompressionMethod,
            last_modified_time: u16,
            last_modified_date: u16,
            offset: u64,
            crc_32: u32,

            pub fn isDirectory(self: Entry) bool {
                return self.name.len > 0 and self.name[self.name.len - 1] == '/';
            }
        };

        const Self = @This();
    
        pub fn init(stream: SeekableStream) !Self {
            const cd_end = try readEndOfCentralDirectory(stream);
            try stream.seekTo(cd_end.cd_offset);
            return .{
                .stream = stream,
                .cd_entries = cd_end.total_cd_entries,
            };
        }

        pub fn next(self: *Self) !?Entry {
            if (self.cd_entry_current >= self.cd_entries) 
                return null;
            self.cd_entry_current += 1;
            const reader = &self.stream.interface;
            try reader.fill(@sizeOf(Signature) + @sizeOf(CentralDirectoryFileHeader));
            const signature = try reader.takeEnum(Signature, .little);
            if (signature != .central_directory_file_header) 
                return error.ZipInvalidCDFileHeader;

            const header = try reader.takeStruct(CentralDirectoryFileHeader, .little);

            if (header.file_name_length > self.name_buf.len)
                return error.ZipFileNameTooLong;
            if (header.disk_number_start != 0) 
                return error.ZipMultidiskUnsupported;
            
            try reader.fill(header.file_name_length);
            try reader.readSliceAll(self.name_buf[0..header.file_name_length]);
            try reader.discardAll(header.extra_field_length);
            try reader.discardAll(header.file_comment_length);

            // TODO check created / required versions in header?

            return .{
                .name = self.name_buf[0..header.file_name_length],
                .compressed_size = header.compressed_size,
                .uncompressed_size = header.uncompressed_size,
                .compression_method = header.compression_method,
                .offset = header.relative_offset_of_local_header,
                .crc_32 = header.crc_32,
                .last_modified_time = header.last_modified_time,
                .last_modified_date = header.last_modified_date,
            };
        }

        pub fn extractFile(self: Self, entry: Entry, output_stream: *std.Io.Writer) !void {
            std.debug.assert(!entry.isDirectory());

            if (entry.compression_method != .deflate and entry.compression_method != .none) 
                return error.ZipUnsupportedCompressionMethod;

            const old_pos = self.stream.logicalPos();
            // TODO lazy-seek if possible?
            try self.stream.seekTo(entry.offset);
            const reader = &self.stream.interface;

            try reader.fill(@sizeOf(Signature) + @sizeOf(LocalFileHeader));
            const signature = try reader.takeEnum(Signature, .little);

            if (signature != .local_file_header) 
                return error.ZipInvalidLocalFileHeader;
            const local_header = try reader.takeStruct(LocalFileHeader, .little);

            const max_len = std.math.maxInt(u32);
            if (entry.compressed_size == max_len or local_header.compressed_size == max_len)
                return error.Zip64Unsupported;
            if (entry.uncompressed_size == max_len or local_header.uncompressed_size == max_len)
                return error.Zip64Unsupported;

            if (local_header.crc_32 != entry.crc_32 and local_header.crc_32 != 0)
                return error.ZipCRCMissmatch;

            if (local_header.compressed_size != entry.compressed_size and local_header.compressed_size != 0)
                return error.ZipFileSizeMissmatch;
            if (local_header.uncompressed_size != entry.uncompressed_size and local_header.uncompressed_size != 0)
                return error.ZipFileSizeMissmatch;

            try reader.discardAll(local_header.file_name_length);
            try reader.discardAll(local_header.extra_field_length);

            var uncompressed_size: u32 = 0;
            
            // TODO pick better size?
            var buf: [8192]u8 = undefined;
            var buf2: [256]u8 = undefined;

            var limited = reader.limited(@enumFromInt(entry.compressed_size), &buf);
            var sink = output_stream.hashed(std.hash.crc.Crc32.init(), &buf2);


            switch (entry.compression_method) {
                .none => {
                    uncompressed_size = @intCast(try limited.interface.streamRemaining(&sink.writer));
                },
                .deflate => {
                    uncompressed_size = @intCast(try flate.decompress(&limited.interface, &sink.writer));
                },
                _ => unreachable,
            }

            try sink.writer.flush();

            if (uncompressed_size != entry.uncompressed_size)
                return error.ZipFileSizeMissmatch;
    
            const final_crc = sink.hasher.final();
            if (final_crc != entry.crc_32)
                return error.ZipCRCMissmatch;

            // TODO lazy-seek if possible?
            try self.stream.seekTo(old_pos);
        }

        pub fn deinit(self: Self) void {
            _ = self;
        }
    };
}

// TODO decompression tests for bad archives
pub fn zipReader(stream: anytype) !ZipReader(@TypeOf(stream)) {
    return ZipReader(@TypeOf(stream)).init(stream);
}

pub const ZipWriter = struct {
    alloc: Alloc,
    writer: *std.Io.Writer,
    cd_entries: std.ArrayList(CDEntry),
    compression_buf: std.Io.Writer.Allocating,
    file_pos: u64 = 0,

    const CDEntry = struct {
        filename: []const u8,
        crc_32: u32,
        compression_method: CompressionMethod = .deflate,
        last_modified_time: u16,
        last_modified_date: u16,
        compressed_size: u32,
        uncompressed_size: u32,
        relative_offset_of_local_header: u32,
    };

    const Self = @This();

    pub fn init(alloc: Alloc, writer: *std.Io.Writer) !Self {
        return .{
            .alloc = alloc,
            .writer = writer,
            .cd_entries = .empty,
            .compression_buf = .init(alloc),
        };
    }

    pub const AddFileOptions = struct {
        filename: []const u8,
        compression_method: CompressionMethod = .deflate,
        last_modified_time: u16 = 0,
        last_modified_date: u16 = 0,
    };

    pub fn addFile(self: *Self, filedata: []const u8, options: AddFileOptions) !void {
        const max_len = std.math.maxInt(u32);
        if (filedata.len >= max_len) 
            return error.ZipFileTooBig;

        try self.cd_entries.ensureUnusedCapacity(self.alloc, 1);
        const filename = try self.alloc.dupe(u8, options.filename);
        errdefer self.alloc.free(filename); 

        const compressed = if (options.compression_method == .deflate) blk: {
            self.compression_buf.clearRetainingCapacity();
            try flate.compress(filedata, &self.compression_buf.writer, self.alloc);
            break :blk self.compression_buf.written();
        } else filedata;

        const crc_32 = std.hash.Crc32.hash(filedata);

        self.cd_entries.appendAssumeCapacity(.{
            .filename = filename,
            .crc_32 = crc_32,
            .compressed_size = @intCast(compressed.len),
            .uncompressed_size = @intCast(filedata.len),
            .compression_method = options.compression_method,
            .last_modified_time = options.last_modified_time,
            .last_modified_date = options.last_modified_date,
            .relative_offset_of_local_header = @intCast(self.file_pos),
        });

        try self.writer.writeInt(u32, @intFromEnum(Signature.local_file_header), .little);
        try self.writer.writeStruct(LocalFileHeader{
            .version_required = AZL_ZIP_VESION,
            .flags = 0,
            .compression = options.compression_method,
            .last_modified_time = options.last_modified_time,
            .last_modified_date = options.last_modified_date,
            .crc_32 = crc_32,
            .compressed_size = @intCast(compressed.len),
            .uncompressed_size = @intCast(filedata.len),
            .file_name_length = @intCast(filename.len),
            .extra_field_length = 0,
        }, .little);

        try self.writer.writeAll(filename);
        try self.writer.writeAll(compressed);

        self.file_pos += compressed.len + filename.len + @sizeOf(LocalFileHeader) + 4;

        if (self.file_pos >= max_len)
            return error.ZipFileTooBig;
    }

    /// Write central direcoty header
    pub fn finish(self: *Self) !void {
        const cd_offset: u32 = @intCast(self.file_pos); 
        var cd_size: u64 = 0;

        for (self.cd_entries.items) |entry| {
            try self.writer.writeInt(u32, @intFromEnum(Signature.central_directory_file_header), .little);
            try self.writer.writeStruct(CentralDirectoryFileHeader{
                .version_required = AZL_ZIP_VESION,
                .version_created = AZL_ZIP_VESION,
                .flags = 0,
                .compression_method = entry.compression_method,
                .last_modified_time = entry.last_modified_time,
                .last_modified_date = entry.last_modified_date,
                .crc_32 = entry.crc_32,
                .compressed_size = entry.compressed_size,
                .uncompressed_size = entry.uncompressed_size,
                .file_name_length = @intCast(entry.filename.len),
                .extra_field_length = 0,
                .file_comment_length = 0,
                .disk_number_start = 0,
                .internal_file_attributes = 0,
                .external_file_attributes = 0,
                .relative_offset_of_local_header = entry.relative_offset_of_local_header,
            }, .little);
            try self.writer.writeAll(entry.filename);
            cd_size += @sizeOf(CentralDirectoryFileHeader) + 4 + entry.filename.len;
        }

        const entries: u16 = @intCast(self.cd_entries.items.len); 
        try self.writer.writeInt(u32, @intFromEnum(Signature.end_of_central_directory), .little);
        try self.writer.writeStruct(EndOfCentralDirectory{
            .this_disk_num = 0,
            .cd_start_disk_num = 0,
            .this_disk_entries = entries,
            .total_cd_entries = entries,
            .cd_size = @intCast(cd_size),
            .cd_offset = cd_offset,
            .file_comment_length = 0,
        }, .little);

        try self.writer.flush();
    }

    pub fn deinit(self: *Self) void {
        for (self.cd_entries.items) |entry| {
            self.alloc.free(entry.filename);
        }
        self.cd_entries.deinit(self.alloc); 
        self.compression_buf.deinit(); 
    }
};
