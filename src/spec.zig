const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ReadError = @import("read.zig").ArchiveParseError;

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

    pub fn newFromReader(allocator: Allocator, reader: anytype) ReadError!Self {
        var buff: [EOCD_SIZE_NOV - SIGNATURE_LENGTH]u8 = undefined;
        if (try reader.readAtLeast(&buff, EOCD_SIZE_NOV - SIGNATURE_LENGTH) == 0) return ReadError.UnexpectedEOFBeforeEOCDR;
        const base: *align(@alignOf(Eocd)) EocdBase = @alignCast(std.mem.bytesAsValue(EocdBase, &buff));
        const comment = try allocator.alloc(u8, base.comment_len);
        if (base.comment_len != 0)
            if (try reader.readAtLeast(comment, base.comment_len) == 0) return ReadError.UnexpectedEOFBeforeEOCDR;

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
        if (try reader.readAtLeast(&buff, CDHF_SIZE_NOV - SIGNATURE_LENGTH) == 0) return ReadError.UnexpectedEOFBeforeCDHF;
        const base: *align(@alignOf(Cdfh)) CdfhBase = @alignCast(std.mem.bytesAsValue(CdfhBase, &buff));

        const name = try allocator.alloc(u8, base.name_len);
        const extra = try allocator.alloc(u8, base.extra_len);
        const comment = try allocator.alloc(u8, base.comment_len);

        _ = try reader.readAtLeast(name, base.name_len);
        _ = try reader.readAtLeast(extra, base.extra_len);
        _ = try reader.readAtLeast(comment, base.comment_len);

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

//
// pub const Lfh = struct {
//     base: LfhBase,
//     name: []const u8,
//     extra: []const u8,
//
//     allocator: Allocator,
//
//     const Self = @This();
//
//     pub fn newFromSlice(allocator: Allocator, reader: anytype) ReadError!Self {
//         var buff: [LFH_SIZE_NOV - SIGNATURE_LENGTH]u8 = undefined;
//         if (try reader.readAtLeast(&buff, LFH_SIZE_NOV - SIGNATURE_LENGTH) == 0) return ReadError.UnexpectedEOFBeforeCDHF;
//
//         const base = std.mem.bytesAsValue(CdfhBase, buff);
//
//         var name = allocator.alloc(u8, base.name_len);
//         var extra = allocator.alloc(u8, base.extra_len);
//
//         try reader.readAtLeast(&name, base.name_len);
//         try reader.readAtLeast(&extra, base.extra_len);
//
//         return Self{ .base = base, .name = name, .extra = extra };
//     }
//
//     pub fn deinit(self: Self) void {
//         self.allocator.free(self.name);
//         self.allocator.free(self.extra);
//     }
// };
