const std = @import("std");
const spec = @import("spec.zig");
const types = @import("types.zig");
const ZipEntry = types.ZipEntry;

const Eocd = spec.Eocd;
const Cdfh = spec.Cdfh;
const Lfh = spec.Lfh;
const HeaderIterator = spec.HeaderIterator;
const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const MAX_BACK_OFFSET = 100 * 1024;

pub const ReadError = error{
    UnexpectedEOFBeforeEOCDR,
    UnexpectedEOFBeforeCDHF,
    NoCDHFSignatureAtOffset,
    OutOfMemory,
} || std.fs.File.OpenError || std.io.StreamSource.ReadError || std.io.StreamSource.SeekError || types.DataError;

const StreamSource = std.io.StreamSource;

const MemberMap = std.StringArrayHashMap(ZipEntry);

pub const ZipArchive = struct {
    stream: *std.io.StreamSource,
    member_count: u16,
    comment: []const u8,
    eocdr_offset: u32,
    cd_offset: u32,
    allocator: Allocator,
    members: MemberMap,

    const Self = @This();

    fn findEocd(allocator: Allocator, reader: anytype) ReadError!headerSearchResult(spec.Eocd, u32) {
        var buff: [4]u8 = undefined;
        if (try reader.readAll(&buff) != 4) return ReadError.UnexpectedEOFBeforeEOCDR;

        var bytes_scanned: u32 = 4;
        var bytes_read: u32 = 4;
        while (bytes_read > 0) {
            if (std.mem.readInt(u32, &buff, .little) == spec.EOCD_SIGNATURE)
                return .{ .header = try spec.Eocd.newFromReader(allocator, reader), .offset = bytes_scanned };

            std.mem.copyForwards(u8, buff[0..], buff[1..]);
            bytes_scanned += bytes_read;
            bytes_read = @intCast(try reader.read(buff[3..]));
        }

        return ReadError.UnexpectedEOFBeforeEOCDR;
    }

    fn entryIndexFromCentralDirectory(allocator: Allocator, reader: anytype, offset: *u32) ReadError!ZipEntry {
        var buff: [4]u8 = undefined;
        if (try reader.readAll(&buff) != 4) return ReadError.UnexpectedEOFBeforeEOCDR;

        if (std.mem.readInt(u32, &buff, .little) == spec.CDFH_SIGNATURE) {
            const cd = try spec.Cdfh.newFromReader(allocator, reader);
            const entry = try ZipEntry.fromCentralDirectoryRecord(cd, offset.*);
            offset.* += spec.SIGNATURE_LENGTH + spec.CDHF_SIZE_NOV + cd.base.name_len + cd.base.extra_len + cd.base.comment_len;
            return entry;
        }
        return ReadError.NoCDHFSignatureAtOffset;
    }

    pub fn openFromPath(allocator: Allocator, path: []const u8) ReadError!Self {
        var file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
        var stream = file.seekableStream();
        return Self.openFromStreamSource(allocator, &stream);
    }

    pub fn openFromStreamSource(allocator: Allocator, stream: *StreamSource) ReadError!Self {
        var mod_stream = stream;
        var reader = std.io.bufferedReader(mod_stream.reader());
        var r = reader.reader();
        const eocd_search = try Self.findEocd(allocator, &r);
        const eocd = eocd_search.header;

        if (eocd.base.disk_number != 0 or eocd.base.cd_start_disk != 0 or eocd.base.cd_entries_disk != eocd.base.total_cd_entries) {
            @panic("Multi volume arcives not supported for now");
        }

        try stream.seekTo(eocd.base.cd_offset);
        var offset = eocd.base.cd_offset;
        var members = MemberMap.init(allocator);
        for (0..eocd.base.total_cd_entries) |_| {
            const entry = try entryIndexFromCentralDirectory(allocator, reader.reader(), &offset);
            try members.put(entry.path, entry);
        }

        return Self{
            .stream = stream,
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
            self.allocator.free(v.path);
            self.allocator.free(v.extra);
            self.allocator.free(v.comment);
        }
        self.members.deinit();
    }
};

fn headerSearchResult(comptime T: type, comptime U: type) type {
    return struct {
        header: T,
        offset: U,
    };
}

test "Find EOCD" {
    const file = @embedFile("build.zip");
    const allocator = testing.allocator;
    const fixedBufferStream = std.io.fixedBufferStream;

    const stream = @constCast(&.{ .const_buffer = fixedBufferStream(file) });
    var archive = try ZipArchive.openFromStreamSource(allocator, stream);
    archive.close();
}

// test "Find CDHF" {
//     const file = @embedFile("build.zip");
//     const allocator = testing.allocator;
//     const eocdr = try findEocdr(allocator, file);
//     defer eocdr.deinit();
//
//     var cds = try parseAllCdfh(allocator, file, eocdr.cd_offset, eocdr.total_cd_entries);
//     defer cds.deinit();
//
//     while (cds.next()) |i| {
//         std.debug.print("{s}\n", .{i.name});
//     }
// }
//
// test "Find LFH" {
//     const file = @embedFile("build.zip");
//     const allocator = testing.allocator;
//     const eocdr = try findEocdr(allocator, file);
//     defer eocdr.deinit();
//
//     var cds = try parseAllCdfh(allocator, file, eocdr.cd_offset, eocdr.total_cd_entries);
//     defer cds.deinit();
//
//     while (cds.next()) |i| {
//         std.debug.print("{s}\n", .{i.name});
//         std.debug.print("{d}\n", .{i.lfh_offset});
//     }
// }
