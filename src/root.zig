const std = @import("std");
const File = std.fs.File;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const EOCD_SIGNATURE = 0x06054b50;
const CDFH_SIGNATURE = 0x02014b50;
const MAX_BACK_OFFSET = 100 * 1024;
const SIGNATURE_LENGTH = 4;

// Sizes for various headers
// The _NOV suffix indicates that these sizes don't account for the variable length data like file name, comment, extra attrs inside the record .
const EOCD_SIZE_NOV = 22;
const CDHF_SIZE_NOV = 46;

const ReadError = error{
    UnexpectedEOFBeforeEOCDR,
    UnexpectedEOFBeforeCDHF,
    NoCDHFSignatureAtOffset,
    OutOfMemory,
};

inline fn read_bytes(comptime T: type, p: *[*]u8) T {
    const bytes = @divExact(@typeInfo(T).Int.bits, 8);
    p.* += bytes;
    return std.mem.readInt(T, @ptrCast(p.* - bytes), .little);
}

// Layout of End of Central Directory Record (EOCD)
const Eocd = struct {
    disk_number: u16,
    start_disk: u16,
    cd_entries_disk: u16,
    total_cd_entries: u16,
    cd_size: u32,
    cd_offset: u32,
    comment_len: u16,
    comment: []const u8,

    allocator: Allocator,

    const Self = @This();

    fn deinit(self: Self) void {
        self.allocator.free(self.comment);
    }

    fn newFromSlice(allocator: Allocator, slice: []const u8) ReadError!Self {
        var slice_ptr: [*]u8 = @constCast(slice.ptr);
        return Self{
            .disk_number = read_bytes(u16, &slice_ptr),
            .start_disk = read_bytes(u16, &slice_ptr),
            .cd_entries_disk = read_bytes(u16, &slice_ptr),
            .total_cd_entries = read_bytes(u16, &slice_ptr),
            .cd_size = read_bytes(u32, &slice_ptr),
            .cd_offset = read_bytes(u32, &slice_ptr),
            .comment_len = read_bytes(u16, &slice_ptr),
            .comment = try allocator.dupe(u8, slice[EOCD_SIZE_NOV - SIGNATURE_LENGTH ..]),
            .allocator = allocator,
        };
    }
};

fn find_eocdr(allocator: Allocator, stream: []const u8) !Eocd {
    var back_offset: usize = 0;
    while (back_offset <= MAX_BACK_OFFSET) : (back_offset += 1) {
        if (stream.len < EOCD_SIZE_NOV + back_offset) {
            return ReadError.UnexpectedEOFBeforeEOCDR;
        }
        // NOTE: Use a double slice approach to ensure its a fixed sized array
        const next_bytes = stream[back_offset .. back_offset + 4][0..4];
        if (std.mem.readInt(u32, next_bytes, .little) == EOCD_SIGNATURE) {
            back_offset += 4;
            return Eocd.newFromSlice(allocator, stream[back_offset..]);
        }
    }
    return ReadError.UnexpectedEOFBeforeEOCDR;
}

// Layout of Central Directory File Header (CDFH)
const Cdfh = struct {
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

    fn newFromSlice(allocator: Allocator, slice: []const u8) ReadError!Self {
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

    fn deinit(self: Self) void {
        self.allocator.free(self.name);
        self.allocator.free(self.extra);
        self.allocator.free(self.comment);
    }
};

const CdfhIterator = struct {
    internal_buffer: std.ArrayList(Cdfh),
    index: u16 = 0,

    const Self = @This();

    fn init(allocator: Allocator, entries: u16) error{OutOfMemory}!Self {
        return Self{ .internal_buffer = try std.ArrayList(Cdfh).initCapacity(allocator, entries), .index = 0 };
    }

    fn insert(self: *Self, cdfh: Cdfh) error{OutOfMemory}!void {
        try self.internal_buffer.append(cdfh);
    }

    fn next(self: *Self) ?Cdfh {
        if (self.index >= self.internal_buffer.items.len) return null;
        self.index += 1;
        const i = self.internal_buffer.items[self.index - 1];
        return i;
    }

    fn deinit(self: *Self) void {
        for (self.internal_buffer.items) |cdfh| {
            cdfh.deinit();
        }
        self.internal_buffer.deinit();
        self.index = 0;
    }
};

fn parse_all_cdfh(allocator: Allocator, stream: []const u8, offset: usize, total_cds: u16) ReadError!CdfhIterator {
    if (offset > stream.len or (stream.len - offset) < CDHF_SIZE_NOV) {
        return ReadError.UnexpectedEOFBeforeCDHF;
    }
    const signature = std.mem.readInt(u32, stream[offset .. offset + 4][0..4], .little);
    if (signature != CDFH_SIGNATURE) {
        return ReadError.NoCDHFSignatureAtOffset;
    }

    var start_byte = offset + 4;
    var entries_read: u16 = 0;
    var cds = try CdfhIterator.init(allocator, total_cds);
    while (entries_read < total_cds) : (entries_read += 1) {
        const cdfh = try Cdfh.newFromSlice(allocator, stream[start_byte..]);
        start_byte += CDHF_SIZE_NOV + cdfh.name_len + cdfh.extra_len + cdfh.comment_len;
        try cds.insert(cdfh);
    }
    return cds;
}

test "Find EOCD" {
    const file = @embedFile("build.zip");
    const allocator = testing.allocator;
    const eocdr = try find_eocdr(allocator, file);
    defer eocdr.deinit();
}

test "Find CDHF" {
    const file = @embedFile("build.zip");
    const allocator = testing.allocator;
    const eocdr = try find_eocdr(allocator, file);
    defer eocdr.deinit();

    var cds = try parse_all_cdfh(allocator, file, eocdr.cd_offset, eocdr.total_cd_entries);
    defer cds.deinit();

    while (cds.next()) |i| {
        std.debug.print("{s}\n", .{i.name});
    }
}
