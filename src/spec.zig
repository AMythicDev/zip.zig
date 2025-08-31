const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ReadError = @import("read.zig").ArchiveParseError;
const FileReader = std.fs.File.Reader;
const assert = std.debug.assert;

// Sizes for various headers
// The _NOV suffix indicates that these sizes don't account for the variable length data like file name, comment, extra attrs inside the record .
pub const EOCD_SIZE_NOV = 22;
pub const CDHF_SIZE_NOV = 46;
pub const LFH_SIZE_NOV = 30;

// Signatures for vatious headers
pub const EOCD_SIGNATURE = 0x06054b50;
pub const CDFH_SIGNATURE = 0x02014b50;
pub const LFH_SIGNATURE = 0x04034b50;
pub const SIGNATURE_LENGTH = 4;

pub const EocdBase = packed struct {
    disk_number: u16,
    cd_start_disk: u16,
    cd_entries_disk: u16,
    total_cd_entries: u16,
    cd_size: u32,
    cd_offset: u32,
    comment_len: u16,
};

// Layout of End of Central Directory Record (EOCD)
pub const Eocd = struct {
    base: EocdBase,
    comment: []const u8,

    allocator: Allocator,

    const Self = @This();

    pub fn newFromReader(allocator: Allocator, reader: *FileReader) ReadError!Self {
        var buff: [EOCD_SIZE_NOV - SIGNATURE_LENGTH]u8 = undefined;
        reader.interface.readSliceAll(&buff) catch return ReadError.UnexpectedEOFBeforeEOCDR;
        const base: *align(1) EocdBase = @alignCast(std.mem.bytesAsValue(EocdBase, &buff));
        const comment = try allocator.alloc(u8, base.comment_len);
        if (base.comment_len != 0)
            readAtleast(reader, comment, base.comment_len) catch return ReadError.UnexpectedEOFBeforeEOCDR;

        return Self{
            .base = base.*,
            .comment = comment,
            .allocator = allocator,
        };
    }
};

pub const CdfhBase = packed struct {
    made_by_ver: u16,
    extract_ver: u16,
    gp_flag: u16,
    compression: u16,
    mod_time: u16,
    mod_date: u16,
    crc32: u32,
    comp_size: u32,
    uncomp_size: u32,
    name_len: u16,
    extra_len: u16,
    comment_len: u16,
    start_disk: u16,
    int_attrs: u16,
    ext_attrs: u32,
    lfh_offset: u32,
};

// Layout of Central Directory File Header (CDFH)
pub const Cdfh = struct {
    base: CdfhBase,
    name: []const u8,
    extra: []const u8,
    comment: []const u8,

    allocator: Allocator,

    const Self = @This();

    pub fn newFromReader(allocator: Allocator, reader: anytype) ReadError!Self {
        var buff: [CDHF_SIZE_NOV - SIGNATURE_LENGTH]u8 = undefined;
        readAtleast(reader, &buff, CDHF_SIZE_NOV - SIGNATURE_LENGTH) catch return ReadError.UnexpectedEOFBeforeCDHF;
        const base: *align(@alignOf(Cdfh)) CdfhBase = @alignCast(std.mem.bytesAsValue(CdfhBase, &buff));

        const name = try allocator.alloc(u8, base.name_len);
        const extra = try allocator.alloc(u8, base.extra_len);
        const comment = try allocator.alloc(u8, base.comment_len);

        readAtleast(reader, name, base.name_len) catch return ReadError.UnexpectedEOFBeforeCDHF;
        readAtleast(reader, extra, base.extra_len) catch return ReadError.UnexpectedEOFBeforeCDHF;
        readAtleast(reader, comment, base.comment_len) catch return ReadError.UnexpectedEOFBeforeCDHF;

        return Self{ .base = base.*, .name = name, .extra = extra, .comment = comment, .allocator = allocator };
    }
};

pub const LfhBase = packed struct {
    extract_ver: u16,
    gp_flag: u16,
    compression: u16,
    mod_time: u16,
    mod_date: u16,
    crc32: u32,
    comp_size: u32,
    uncomp_size: u32,
    name_len: u16,
    extra_len: u16,
};

pub const Lfh = struct {
    base: LfhBase,
    name: []const u8,
    extra: []const u8,

    allocator: Allocator,

    const Self = @This();

    pub fn newFromReader(allocator: Allocator, reader: anytype) ReadError!Self {
        var buff: [LFH_SIZE_NOV - SIGNATURE_LENGTH]u8 = undefined;
        readAtleast(reader, &buff, LFH_SIZE_NOV - SIGNATURE_LENGTH) catch return ReadError.UnexpectedEOFBeforeLFH;

        const base: *align(1) LfhBase = @alignCast(std.mem.bytesAsValue(LfhBase, &buff));

        const name = try allocator.alloc(u8, base.name_len);
        const extra = try allocator.alloc(u8, base.extra_len);

        readAtleast(reader, name, base.name_len) catch return ReadError.UnexpectedEOFBeforeLFH;
        readAtleast(reader, extra, base.extra_len) catch return ReadError.UnexpectedEOFBeforeLFH;

        return Self{ .base = base.*, .name = name, .extra = extra, .allocator = allocator };
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.name);
        self.allocator.free(self.extra);
    }
};

/// Directly from Zig v0.14.1 lib/std/io/Reader.zig
fn readAtleast(reader: *FileReader, buffer: []u8, len: u64) ReadError!void {
    assert(len <= try reader.getSize());
    var index: usize = 0;
    while (index < len) {
        const amt = try reader.read(buffer[index..]);
        if (amt == 0) break;
        index += amt;
    }
    if (index < len) return std.io.Reader.Error.EndOfStream;
}
