const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ReadError = @import("read.zig").ReadError;

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

// Layout of End of Central Directory Record (EOCD)
pub const Eocd = struct {
    disk_number: u16,
    cd_start_disk: u16,
    cd_entries_disk: u16,
    total_cd_entries: u16,
    cd_size: u32,
    cd_offset: u32,
    comment_len: u16,
    comment: []const u8,

    allocator: Allocator,

    const Self = @This();

    pub fn deinit(self: Self) void {
        self.allocator.free(self.comment);
    }

    pub fn newFromReader(allocator: Allocator, reader: anytype) ReadError!Self {
        var buff: [EOCD_SIZE_NOV]u8 = undefined;
        if (try reader.readAtLeast(&buff, EOCD_SIZE_NOV) == 0) return ReadError.UnexpectedEOFBeforeEOCDR;
        var slice_ptr = buff[0..].ptr;
        var eocd = Self{
            .disk_number = read_bytes(u16, &slice_ptr),
            .cd_start_disk = read_bytes(u16, &slice_ptr),
            .cd_entries_disk = read_bytes(u16, &slice_ptr),
            .total_cd_entries = read_bytes(u16, &slice_ptr),
            .cd_size = read_bytes(u32, &slice_ptr),
            .cd_offset = read_bytes(u32, &slice_ptr),
            .comment_len = read_bytes(u16, &slice_ptr),
            .comment = undefined,
            .allocator = allocator,
        };
        eocd.comment = try allocator.dupe(u8, slice_ptr[0..eocd.comment_len]);
        return eocd;
    }
};

// Layout of Central Directory File Header (CDFH)
pub const Cdfh = struct {
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
    name: []const u8,
    extra: []const u8,
    comment: []const u8,

    allocator: Allocator,

    const Self = @This();

    pub fn newFromSlice(allocator: Allocator, slice: []const u8) ReadError!Self {
        var slice_ptr: [*]u8 = @constCast(slice.ptr);
        var cdfh = Self{
            .made_by_ver = read_bytes(u16, &slice_ptr),
            .extract_ver = read_bytes(u16, &slice_ptr),
            .gp_flag = read_bytes(u16, &slice_ptr),
            .compression = read_bytes(u16, &slice_ptr),
            .mod_time = read_bytes(u16, &slice_ptr),
            .mod_date = read_bytes(u16, &slice_ptr),
            .crc32 = read_bytes(u32, &slice_ptr),
            .comp_size = read_bytes(u32, &slice_ptr),
            .uncomp_size = read_bytes(u32, &slice_ptr),
            .name_len = read_bytes(u16, &slice_ptr),
            .extra_len = read_bytes(u16, &slice_ptr),
            .comment_len = read_bytes(u16, &slice_ptr),
            .start_disk = read_bytes(u16, &slice_ptr),
            .int_attrs = read_bytes(u16, &slice_ptr),
            .ext_attrs = read_bytes(u32, &slice_ptr),
            .lfh_offset = read_bytes(u32, &slice_ptr),
            .allocator = allocator,
            .name = undefined,
            .extra = undefined,
            .comment = undefined,
        };
        cdfh.name = try allocator.dupe(u8, slice_ptr[0..cdfh.name_len]);
        cdfh.extra = try allocator.dupe(u8, slice_ptr[cdfh.name_len .. cdfh.name_len + cdfh.extra_len]);
        cdfh.comment = try allocator.dupe(u8, slice_ptr[cdfh.name_len + cdfh.extra_len .. cdfh.name_len + cdfh.extra_len + cdfh.comment_len]);
        return cdfh;
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.name);
        self.allocator.free(self.extra);
        self.allocator.free(self.comment);
    }
};

pub fn HeaderIterator(comptime T: type) type {
    return struct {
        internal_buffer: std.ArrayList(T),
        index: u16 = 0,

        const Self = @This();

        pub fn init(allocator: Allocator, entries: u16) error{OutOfMemory}!Self {
            return Self{ .internal_buffer = try std.ArrayList(T).initCapacity(allocator, entries), .index = 0 };
        }

        pub fn insert(self: *Self, header: T) error{OutOfMemory}!void {
            try self.internal_buffer.append(header);
        }

        pub fn next(self: *Self) ?T {
            if (self.index >= self.internal_buffer.items.len) return null;
            self.index += 1;
            return self.internal_buffer.items[self.index - 1];
        }

        pub fn deinit(self: *Self) void {
            for (self.internal_buffer.items) |header| {
                header.deinit();
            }
            self.internal_buffer.deinit();
            self.index = 0;
        }
    };
}

pub const Lfh = struct {
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
    name: []const u8,
    extra: []const u8,

    allocator: Allocator,

    const Self = @This();

    pub fn newFromSlice(allocator: Allocator, slice: []const u8) ReadError!Self {
        var slice_ptr: [*]u8 = @constCast(slice.ptr);
        var cdfh = Self{
            .extract_ver = read_bytes(u16, &slice_ptr),
            .gp_flag = read_bytes(u16, &slice_ptr),
            .compression = read_bytes(u16, &slice_ptr),
            .mod_time = read_bytes(u16, &slice_ptr),
            .mod_date = read_bytes(u16, &slice_ptr),
            .crc32 = read_bytes(u32, &slice_ptr),
            .comp_size = read_bytes(u32, &slice_ptr),
            .uncomp_size = read_bytes(u32, &slice_ptr),
            .name_len = read_bytes(u16, &slice_ptr),
            .extra_len = read_bytes(u16, &slice_ptr),
            .allocator = allocator,
            .name = undefined,
            .extra = undefined,
        };
        cdfh.name = try allocator.dupe(u8, slice_ptr[0..cdfh.name_len]);
        cdfh.extra = try allocator.dupe(u8, slice_ptr[cdfh.name_len .. cdfh.name_len + cdfh.extra_len]);
        return cdfh;
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.name);
        self.allocator.free(self.extra);
    }
};

inline fn read_bytes(comptime T: type, p: *[*]u8) T {
    const bytes = @divExact(@typeInfo(T).Int.bits, 8);
    p.* += bytes;
    return std.mem.readInt(T, @ptrCast(p.* - bytes), .little);
}
