const std = @import("std");
const spec = @import("spec.zig");
const types = @import("types.zig");
const builtin = @import("builtin");
const ZipEntry = types.ZipEntry;

const Eocd = spec.Eocd;
const Cdfh = spec.Cdfh;
const Lfh = spec.Lfh;
const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const MAX_BACK_OFFSET = 100 * 1024;

pub const ArchiveParseError = error{
    UnexpectedEOFBeforeEOCDR,
    UnexpectedEOFBeforeCDHF,
    UnexpectedEOFBeforeLFH,
    NoCDHFSignatureAtOffset,
    DateTimeRange,
    OutOfMemory,
} || std.fs.File.OpenError || File.Reader.SeekError || File.Reader.SizeError || std.io.Reader.Error;

const MemberMap = std.StringArrayHashMap(ZipEntry);

pub const ZipArchive = struct {
    stream: *File.Reader,
    member_count: u16,
    comment: []const u8,
    eocdr_offset: u32,
    cd_offset: u32,
    allocator: Allocator,
    members: MemberMap,

    const Self = @This();

    fn findEocd(allocator: Allocator, reader: *File.Reader) ArchiveParseError!headerSearchResult(spec.Eocd, u32) {
        var buff: [4]u8 = undefined;
        const reader_len = try reader.getSize();
        if (reader_len < 4) return ArchiveParseError.UnexpectedEOFBeforeEOCDR;

        var start_range = reader_len - 32;
        var end_range = reader_len;
        try reader.seekTo(start_range);

        var bytes_scanned: u32 = 0;
        var bytes_read: u32 = @intCast(try reader.read(buff[0..]));
        while (bytes_read > 0) {
            if (std.mem.readInt(u32, &buff, .little) == spec.EOCD_SIGNATURE)
                return .{ .header = try spec.Eocd.newFromReader(allocator, reader), .offset = @as(u32, @intCast(start_range)) + bytes_scanned };

            @memmove(buff[0..3], buff[1..]);
            bytes_scanned += bytes_read;
            bytes_read = @intCast(try reader.read(buff[3..]));
            if (start_range + bytes_scanned + 1 == end_range) {
                start_range = start_range - 36;
                end_range = end_range - 32;
                bytes_scanned = 0;
                try reader.seekTo(start_range);
                bytes_read = @intCast(try reader.read(buff[0..]));
            }
        }

        return ArchiveParseError.UnexpectedEOFBeforeEOCDR;
    }

    fn entryIndexFromCentralDirectory(allocator: Allocator, reader: *File.Reader, offset: *u32) ArchiveParseError!ZipEntry {
        var buff: [4]u8 = undefined;
        if (try reader.read(&buff) != 4) return ArchiveParseError.UnexpectedEOFBeforeEOCDR;

        if (std.mem.readInt(u32, &buff, .little) == spec.CDFH_SIGNATURE) {
            const cd = try spec.Cdfh.newFromReader(allocator, reader);
            try reader.seekTo(cd.base.lfh_offset + spec.SIGNATURE_LENGTH);

            const lfh = try spec.Lfh.newFromReader(allocator, reader);

            defer allocator.free(cd.extra);
            defer allocator.free(lfh.name);

            const entry = try ZipEntry.fromCentralDirectoryRecord(reader, cd, lfh, offset.*);

            offset.* += spec.CDHF_SIZE_NOV + cd.base.name_len + cd.base.extra_len + cd.base.comment_len;
            return entry;
        }
        return ArchiveParseError.NoCDHFSignatureAtOffset;
    }

    pub fn openFromPath(allocator: Allocator, path: []const u8) ArchiveParseError!Self {
        var file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
        var stream = file.seekableStream();
        return Self.openFromFile.Reader(allocator, &stream);
    }

    pub fn openFromFileReader(allocator: Allocator, reader: *std.fs.File.Reader) ArchiveParseError!Self {
        const eocd_search = try Self.findEocd(allocator, reader);
        const eocd = eocd_search.header;

        if (eocd.base.disk_number != 0 or eocd.base.cd_start_disk != 0 or eocd.base.cd_entries_disk != eocd.base.total_cd_entries) {
            @panic("Multi volume arcives not supported for now");
        }

        try reader.seekTo(eocd.base.cd_offset);
        var offset = eocd.base.cd_offset;
        var members = MemberMap.init(allocator);
        for (0..eocd.base.total_cd_entries) |_| {
            const entry = try entryIndexFromCentralDirectory(allocator, reader, &offset);
            try members.put(entry.name, entry);
            try reader.seekTo(offset);
        }

        return Self{
            .stream = reader,
            .member_count = eocd.base.total_cd_entries,
            .comment = eocd.comment,
            .cd_offset = eocd.base.cd_offset,
            .eocdr_offset = eocd_search.offset,
            .allocator = allocator,
            .members = members,
        };
    }

    pub fn close(self: *Self) void {
        self.allocator.free(self.comment);

        const members = self.members.values();

        for (members) |v| {
            self.allocator.free(v.name);
            self.allocator.free(v.extra);
            self.allocator.free(v.comment);
        }
        self.members.deinit();
    }

    pub fn getFileByName(self: Self, name: []const u8) ?ZipEntry {
        return self.members.get(name);
    }

    pub fn getFileByIndex(self: Self, index: usize) ?ZipEntry {
        if (index >= self.member_count) return null;
        return self.members.unmanaged.entries.get(index).value;
    }

    pub fn getIndexByPath(self: Self, path: []const u8) ?usize {
        return self.members.getIndex(path);
    }
};

fn headerSearchResult(comptime T: type, comptime U: type) type {
    return struct {
        header: T,
        offset: U,
    };
}

test "Parse EOCD" {
    const dir = std.fs.cwd();
    const file = try dir.openFile("build.zip", .{ .mode = .read_only });
    var buf: [4096]u8 = undefined;
    var r = std.fs.File.Reader.init(file, &buf);
    const allocator = testing.allocator;
    var archive = try ZipArchive.openFromFileReader(allocator, &r);
    defer archive.close();

    try testing.expect(archive.member_count != 0);
}

pub fn loadZip(comptime path: []const u8) std.fs.File.OpenError!std.fs.File.Reader {
    const dir = std.fs.cwd();
    const file = try dir.openFile(path, .{ .mode = .read_only });
    var buf: [4096]u8 = undefined;
    const r = std.fs.File.Reader.init(file, &buf);
    return r;
}

test "Parse CDFH" {
    var r = try loadZip("build.zip");
    const allocator = testing.allocator;
    var archive = try ZipArchive.openFromFileReader(allocator, &r);

    try testing.expect(archive.getFileByIndex(0) != null);
    try testing.expectEqual(archive.getFileByIndex(1), null);

    archive.close();
}

test "Read uncompressed data" {
    var r = try loadZip("build.zip");
    const allocator = testing.allocator;
    var archive = try ZipArchive.openFromFileReader(allocator, &r);
    defer archive.close();
    var file = archive.getFileByIndex(0).?;

    var buffer: [1000]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    _ = try file.decompressWriter(&writer);
}

test "Read flate compressed data" {
    var r = try loadZip("readme.zip");
    const allocator = testing.allocator;
    var archive = try ZipArchive.openFromFileReader(allocator, &r);
    defer archive.close();
    var file = archive.getFileByIndex(0).?;

    var buffer: [2000]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    _ = try file.decompressWriter(&writer);
}
