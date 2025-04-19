const std = @import("std");

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
    const stream_len = try stream.getEndPos();
    const cd_end_len = @sizeOf(EndOfCentralDirectory) + 4;
    if (stream_len < cd_end_len) 
        return error.ZipNoCentralDirectory;
    try stream.seekTo(stream_len - cd_end_len);

    const reader = stream.context.reader();
    const signature: Signature = @enumFromInt(try reader.readInt(u32, .little));
    if (signature != .end_of_central_directory) 
        return error.ZipNoCentralDirectory;
    const cd_end = try reader.readStructEndian(EndOfCentralDirectory, .little);

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
            if (self.cd_entry_current >= self.cd_entries) return null;
            self.cd_entry_current += 1;
            const reader = self.stream.context.reader();
            const signature: Signature = @enumFromInt(try reader.readInt(u32, .little));
            if (signature != .central_directory_file_header) 
                return error.ZipInvalidCDFileHeader;

            const header = try reader.readStructEndian(CentralDirectoryFileHeader, .little);
            
            try reader.readNoEof(self.name_buf[0..header.file_name_length]);
            try reader.skipBytes(header.extra_field_length, .{});
            try reader.skipBytes(header.file_comment_length, .{});

            if (header.file_name_length > self.name_buf.len)
                return error.ZipFileNameTooLong;
            if (header.disk_number_start != 0) 
                return error.ZipMultidiskUnsupported;

            // TODO check created / required versions in header?

            return .{
                .name = self.name_buf[0..header.file_name_length],
                .compressed_size = header.compressed_size,
                .uncompressed_size = header.uncompressed_size,
                .compression_method = header.compression_method,
                .offset = header.relative_offset_of_local_header,
                .crc_32 = header.crc_32,
            };
        }

        pub fn extractFile(self: Self, entry: Entry, output_steam: anytype) !void {
            std.debug.assert(!entry.isDirectory());

            if (entry.compression_method != .deflate and entry.compression_method != .none) 
                return error.ZipUnsupportedCompressionMethod;

            const old_pos = try self.stream.getPos();
            try self.stream.seekTo(entry.offset);
            const raw_reader = self.stream.context.reader();
            var buf_reader = std.io.bufferedReader(raw_reader);
            const reader = buf_reader.reader();

            const signature: Signature = @enumFromInt(try reader.readInt(u32, .little));
            if (signature != .local_file_header) 
                return error.ZipInvalidLocalFileHeader;
            const local_header: LocalFileHeader = try reader.readStructEndian(LocalFileHeader, .little);

            if (entry.compressed_size == 0xFFFF)
                return error.Zip64Unsupported;
            if (entry.uncompressed_size == 0xFFFF)
                return error.Zip64Unsupported;

            // TODO figure out why this checks fail on most *wild* zip files

            // if (local_header.crc_32 != entry.crc_32)
            //     return error.ZipCRCMissmatch;

            // if (local_header.compressed_size != entry.compressed_size)
            //     return error.ZipFileSizeMissmatch;
            // if (local_header.uncompressed_size != entry.uncompressed_size)
            //     return error.ZipFileSizeMissmatch;

            try reader.skipBytes(local_header.file_name_length, .{});
            try reader.skipBytes(local_header.extra_field_length, .{});

            var crc = std.hash.crc.Crc32.init();
            var uncompressed_size: u32 = 0;
            
            switch(entry.compression_method) {
                .none => {
                    var lr = std.io.limitedReader(reader, entry.compressed_size);
                    var buf: [4096]u8 = undefined;
                    while (true) {
                        const len = try lr.read(&buf);
                        if (len == 0) break;

                        uncompressed_size += @intCast(len);
                        if (uncompressed_size > entry.uncompressed_size)
                            return error.ZipFileSizeMissmatch;

                        crc.update(buf[0..len]);
                        try output_steam.writeAll(buf[0..len]);
                    }
                },
                .deflate => {
                    var lr = std.io.limitedReader(reader, entry.compressed_size);
                    var decompressor = std.compress.flate.decompressor(lr.reader());
                    while (try decompressor.next()) |buf| {
                        uncompressed_size += @intCast(buf.len);
                        if (uncompressed_size > entry.uncompressed_size)
                            return error.ZipFileSizeMissmatch;

                        crc.update(buf);
                        try output_steam.writeAll(buf);
                    }
                },
                _ => unreachable,
            }

            if (uncompressed_size != entry.uncompressed_size)
                return error.ZipFileSizeMissmatch;

            if (crc.final() != entry.crc_32)
                return error.ZipCRCMissmatch;

            try self.stream.seekTo(old_pos);
        }

        pub fn deinit(self: Self) void {
            _ = self;
        }
    };
}

// TODO decompression tests for bad archives
