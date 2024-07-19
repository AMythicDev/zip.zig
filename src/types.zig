const std = @import("std");
const read = @import("read.zig");
const spec = @import("spec.zig");

const ReadError = read.ReadError;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const StreamSource = std.io.StreamSource;

pub const ZipArchive = struct {
    stream: std.io.StreamSource,
    members: u16,
    comment: []const u8,
    eocdr_offset: u32,
    cd_offset: u32,

    const Self = @This();

    fn findEocd(allocator: Allocator, reader: anytype) ReadError!headerSearchResult(spec.Eocd, u32) {
        var buff: [4]u8 = undefined;
        if (try reader.readAll(&buff) != 4) {
            return ReadError.UnexpectedEOFBeforeEOCDR;
        }

        var bytes_scanned: u32 = 4;
        var bytes_read: u32 = 4;
        while (bytes_read > 0) {
            if (std.mem.readInt(u32, &buff, .little) == spec.EOCD_SIGNATURE) {
                return .{ .header = try spec.Eocd.newFromReader(allocator, reader), .offset = bytes_scanned };
            }
            std.mem.copyForwards(u8, buff[0..], buff[1..]);
            bytes_scanned += bytes_read;
            bytes_read = @intCast(try reader.read(buff[3..]));
        }

        return ReadError.UnexpectedEOFBeforeEOCDR;
    }

    pub fn openFromPath(allocator: Allocator, path: []const u8) ReadError!Self {
        var file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
        var stream = file.seekableStream();
        var reader = std.io.bufferedReader(stream.reader());
        const eocd_search = try Self.findEocd(allocator, &reader.reader());
        const eocd = eocd_search.header;

        if (eocd.disk_number != 0 or eocd.cd_start_disk != 0 or eocd.cd_entries_disk != eocd.total_cd_entries) {
            @panic("Multi volume arcives not supported for now");
        }

        return Self{
            .stream = stream,
            .members = eocd.total_cd_entries,
            .comment = eocd.comment,
            .cd_offset = eocd.cd_offset,
            .eocdr_offset = eocd_search.offset,
            .start_offset = 0,
        };
    }

    pub fn openFromStreamSource(allocator: Allocator, stream: StreamSource) ReadError!Self {
        var mod_stream = stream;
        var reader = std.io.bufferedReader(mod_stream.reader());
        var r = reader.reader();
        const eocd_search = try Self.findEocd(allocator, &r);
        const eocd = eocd_search.header;
        defer eocd.deinit();

        if (eocd.disk_number != 0 or eocd.cd_start_disk != 0 or eocd.cd_entries_disk != eocd.total_cd_entries) {
            @panic("Multi volume arcives not supported for now");
        }

        return Self{
            .stream = stream,
            .members = eocd.total_cd_entries,
            .comment = try allocator.dupe(u8, eocd.comment),
            .cd_offset = eocd.cd_offset,
            .eocdr_offset = eocd_search.offset,
        };
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

    const archive = try ZipArchive.openFromStreamSource(allocator, .{ .const_buffer = fixedBufferStream(file) });
    std.debug.print("{d}", .{archive.cd_offset});
    std.debug.print("{d}", .{archive.eocdr_offset});
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
