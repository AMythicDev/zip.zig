const spec = @import("spec.zig");
const std = @import("std");

pub const ZipEntry = struct {
    path: []const u8,
    modtime: DateTime,
    comp_size: u32,
    uncomp_size: u32,
    lfh_offset: u32,
    cd_offset: u32,
    compression: u16,
    crc32: u32,
    comment: []const u8,
    extra: []const u8,
    is_dir: bool,

    const Self = @This();

    const IS_DIR: u32 = 1 << 4;

    pub fn fromCentralDirectoryRecord(cd: spec.Cdfh, offset: u32) DataError!Self {
        return ZipEntry{
            .path = cd.name,
            .cd_offset = offset,
            .comment = cd.comment,
            .extra = cd.extra,
            .comp_size = cd.base.comp_size,
            .uncomp_size = cd.base.uncomp_size,
            .lfh_offset = cd.base.lfh_offset,
            .compression = undefined,
            .crc32 = undefined,
            .is_dir = cd.base.ext_attrs & IS_DIR != 0,
            .modtime = try DateTime.fromDos(cd.base.mod_time, cd.base.mod_date),
        };
    }
};

pub const DataError = error{DateTimeRange};

pub const DateTime = struct {
    second: u8,
    minute: u8,
    hour: u8,
    day: u8,
    month: u8,
    year: u16,

    fn fromDos(dos_time: u16, dos_date: u16) DataError!@This() {
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

        return DataError.DateTimeRange;
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
