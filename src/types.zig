const spec = @import("spec.zig");
const std = @import("std");
const read = @import("read.zig");
const ArchiveParseError = read.ArchiveParseError;
const File = std.fs.File;

const Allocator = std.mem.Allocator;

pub const ZipEntry = struct {
    reader: *File.Reader,
    name: []const u8,
    modtime: DateTime,
    made_by_ver: u8,
    os: OperatingSystem,
    comp_size: u32,
    uncomp_size: u32,
    lfh_offset: u32,
    cd_offset: u32,
    external_attrs: u32,
    compression: Compression,
    // Level of compression for deflate to be used when writing the file.
    // 0 for normal, 1 for maximum, 2 for fast, 3 for super fast.
    compression_level: ?i64,
    crc32: u32,
    comment: []const u8,
    extra: []const u8,
    is_dir: bool,

    const Self = @This();

    const IS_DIR: u32 = 1 << 4;

    pub fn fromCentralDirectoryRecord(reader: *File.Reader, cd: spec.Cdfh, lfh: spec.Lfh, offset: u32) ArchiveParseError!Self {
        const is_dir = cd.base.ext_attrs & IS_DIR != 0;
        return ZipEntry{
            .reader = reader,
            .name = cd.name,
            .cd_offset = offset,
            .comment = cd.comment,
            .os = OperatingSystem.detectOS(@intCast(cd.base.made_by_ver >> 8)),
            .made_by_ver = @intCast(cd.base.made_by_ver & 0xff),
            .extra = lfh.extra,
            .comp_size = cd.base.comp_size,
            .uncomp_size = cd.base.uncomp_size,
            .lfh_offset = cd.base.lfh_offset,
            .compression = Compression.detectCompression(cd.base.compression),
            .compression_level = null,
            .crc32 = cd.base.crc32,
            .external_attrs = cd.base.ext_attrs,
            .modtime = try DateTime.fromDos(cd.base.mod_time, cd.base.mod_date),
            .is_dir = is_dir,
        };
    }

    pub fn decompressWriter(self: *Self, writer: *std.Io.Writer) !u32 {
        try self.reader.seekTo(self.lfh_offset + spec.LFH_SIZE_NOV + self.name.len + self.extra.len);

        var total_uncompressed: u64 = 0;
        var hash = std.hash.Crc32.init();

        switch (self.compression) {
            Compression.Store => {
                var buff: [4096]u8 = undefined;
                total_uncompressed = try self.reader.interface.stream(writer, .limited(self.comp_size));
                var size = try self.reader.interface.readSliceShort(&buff);
                while (size != 0) {
                    const actsize = @min(size, self.comp_size);
                    try writer.writeAll(buff[0..actsize]);
                    hash.update(buff[0..actsize]);
                    total_uncompressed += @intCast(actsize);
                    size = try self.reader.interface.readSliceShort(&buff);
                }
            },
            Compression.Deflate => {
                var lreader_buf: [4096]u8 = undefined;
                var limited = self.reader.interface.limited(.limited(self.comp_size), &lreader_buf);
                const lreader = &limited.interface;

                var dbuff: [std.compress.flate.max_window_len]u8 = undefined;

                var decompressor = std.compress.flate.Decompress.init(lreader, .raw, &dbuff);
                const reader = &decompressor.reader;

                var buff: [4096]u8 = undefined;
                var n = try reader.readSliceShort(&buff);
                while (n != 0) {
                    try writer.writeAll(buff[0..n]);
                    hash.update(buff[0..n]);
                    total_uncompressed += @intCast(n);
                    n = try reader.readSliceShort(&buff);
                }
            },
            // else => error.UnsupportedCompressionMethod,
        }

        if (total_uncompressed != self.uncomp_size) return error.ZipUncompressSizeMismatch;
        return hash.final();
    }

    inline fn unixPerms(self: Self) ?u16 {
        const S_IFDIR = 0o0040000;
        const S_IFREG = 0o0100000;

        if (self.external_attrs == 0) return null;
        if (self.os == .Unix) return @intCast(self.external_attrs >> 16) else if (self.os == .Dos) {
            var mode = if (self.external_attributes & 0x10 == 0x10)
                S_IFDIR | 0o0775
            else
                S_IFREG | 0o0664;
            if (self.external_attributes & 0x01 == 0x01)
                mode &= 0o0555;
            return mode;
        }
        return null;
    }
};

pub const DateTime = struct {
    second: u8,
    minute: u8,
    hour: u8,
    day: u8,
    month: u8,
    year: u16,

    fn fromDos(dos_time: u16, dos_date: u16) error{DateTimeRange}!@This() {
        var second = (dos_time & 0x1f) * 2;
        const minute = (dos_time >> 5) & 0x3f;
        const hour = (dos_time >> 11);
        const day = (dos_date & 0x1f);
        const month = ((dos_date >> 5) & 0xf) - 1;
        const year = (dos_date >> 9) + 1980;

        if (DateTime.checkValidDateTime(second, minute, hour, day, month, year)) {
            // exFAT cannot handle leap seconds
            second = @min(second, 58);
            return DateTime{
                .second = @intCast(second),
                .minute = @intCast(minute),
                .hour = @intCast(day),
                .day = @intCast(day),
                .month = @intCast(month),
                .year = @intCast(year),
            };
        }

        return error.DateTimeRange;
    }

    fn checkValidDateTime(second: u16, minute: u16, hour: u16, day: u16, month: u16, year: u16) bool {
        if (1980 <= year and year <= 2107 and 1 <= month and month <= 12 and 1 <= day and day <= 31 and 1 <= hour and hour <= 23 and minute <= 59 and second <= 60) {
            const max_days: u8 = switch (month) {
                2 => b: {
                    break :b if (DateTime.isLeapYear(year)) @as(u8, 29) else @as(u8, 28);
                },
                1, 3, 5, 7, 8, 10, 12 => 31,
                4, 6, 9, 11 => 30,
                else => unreachable,
            };
            if (day > max_days) {
                return false;
            }
            return true;
        }

        return false;
    }

    fn isLeapYear(year: u16) bool {
        return ((year % 4 == 0) and ((year % 25 != 0) or (year % 16 == 0)));
    }
};

pub const OperatingSystem = enum(u8) {
    Dos = 0,
    Unix = 3,
    Unknown,

    fn detectOS(code: u8) OperatingSystem {
        if (code == @intFromEnum(OperatingSystem.Dos))
            return OperatingSystem.Dos
        else if (code == @intFromEnum(OperatingSystem.Unix))
            return OperatingSystem.Unix
        else
            return OperatingSystem.Unknown;
    }
};

pub const Compression = enum(u16) {
    Store = 0,
    Deflate = 8,

    fn detectCompression(val: u16) Compression {
        return switch (val) {
            @intFromEnum(Compression.Store) => Compression.Store,
            @intFromEnum(Compression.Deflate) => Compression.Deflate,
            else => @panic("Compression method not supported"),
        };
    }
};
