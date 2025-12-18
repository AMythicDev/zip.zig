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
} || std.fs.File.OpenError || File.Reader.SeekError || File.Reader.SizeError || std.Io.Reader.Error;

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

    fn findEocd(allocator: Allocator, freader: *File.Reader) ArchiveParseError!headerSearchResult(spec.Eocd, u32) {
        const file_len = try freader.getSize();
        if (file_len < spec.EOCD_SIZE_NOV) return ArchiveParseError.UnexpectedEOFBeforeEOCDR;

        const search_limit = spec.MAX_COMMENT_SIZE + spec.EOCD_SIZE_NOV;
        const stop_offset = if (file_len > search_limit) file_len - search_limit else 0;

        const buflen = 4096;
        var buf: [buflen]u8 = [_]u8{0} ** buflen;

        var window_end = file_len;

        const VecLen = 32;
        const V = @Vector(VecLen, u8);
        const sig_first_byte: u8 = @intCast(spec.EOCD_SIGNATURE & 0xFF);
        const sig_first: V = @splat(sig_first_byte);

        while (window_end > stop_offset) {
            var window_start: u64 = 0;
            if (window_end > buflen) window_start = window_end - buflen;
            if (window_start < stop_offset) window_start = stop_offset;

            const n = window_end - window_start;
            try freader.seekTo(window_start);
            try freader.interface.readSliceAll(buf[0..n]);

            var i: usize = n;
            while (i > 0) {
                if (i >= VecLen) i -= VecLen else i = 0;

                const chunk: V = buf[i..][0..VecLen].*;
                const matches = chunk == sig_first;

                if (@reduce(.Or, matches)) {
                    const matches_arr: [VecLen]bool = matches;
                    var k: usize = VecLen;
                    while (k > 0) {
                        k -= 1;
                        if (matches_arr[k]) {
                            const off = i + k;
                            const sig = std.mem.readInt(u32, buf[off..][0..4], .little);
                            if (sig == spec.EOCD_SIGNATURE) {
                                const abs_offset = window_start + off;
                                try freader.seekTo(abs_offset + 4);
                                return .{ .header = try spec.Eocd.newFromReader(allocator, freader), .offset = @intCast(abs_offset) };
                            }
                        }
                    }
                }
            }

            if (window_start <= stop_offset) break;
            window_end = window_start + 3;
        }

        return ArchiveParseError.UnexpectedEOFBeforeEOCDR;
    }

    fn entryIndexFromCentralDirectory(allocator: Allocator, freader: *File.Reader, offset: *u32) ArchiveParseError!ZipEntry {
        var buff: [4]u8 = undefined;
        const reader = &freader.interface;
        reader.readSliceAll(&buff) catch return ArchiveParseError.UnexpectedEOFBeforeEOCDR;

        if (std.mem.readInt(u32, &buff, .little) == spec.CDFH_SIGNATURE) {
            const cd = try spec.Cdfh.newFromReader(allocator, freader);
            try freader.seekTo(cd.base.lfh_offset + spec.SIGNATURE_LENGTH);

            const lfh = try spec.Lfh.newFromReader(allocator, freader);

            defer allocator.free(cd.extra);
            defer allocator.free(lfh.name);

            const entry = try ZipEntry.fromCentralDirectoryRecord(freader, cd, lfh, offset.*);

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
