const std = @import("std");
const spec = @import("spec.zig");
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
} || std.fs.File.OpenError || std.io.StreamSource.ReadError;

// fn findEocdr(allocator: Allocator, stream: []const u8) !Eocd {
//     var back_offset: usize = 0;
//     while (back_offset <= MAX_BACK_OFFSET) : (back_offset += 1) {
//         if (stream.len < spec.EOCD_SIZE_NOV + back_offset) {
//             return ReadError.UnexpectedEOFBeforeEOCDR;
//         }
//         // NOTE: Use a double slice approach to ensure its a fixed sized array
//         const next_bytes = stream[back_offset .. back_offset + 4][0..4];
//         if (std.mem.readInt(u32, next_bytes, .little) == spec.EOCD_SIGNATURE) {
//             back_offset += 4;
//             return Eocd.newFromSlice(allocator, stream[back_offset..]);
//         }
//     }
//     return ReadError.UnexpectedEOFBeforeEOCDR;
// }
//
// fn parseAllCdfh(allocator: Allocator, stream: []const u8, offset: usize, total_cds: u16) ReadError!HeaderIterator(Cdfh) {
//     if (offset > stream.len or (stream.len - offset) < spec.CDHF_SIZE_NOV) {
//         return ReadError.UnexpectedEOFBeforeCDHF;
//     }
//     const signature = std.mem.readInt(u32, stream[offset .. offset + 4][0..4], .little);
//     if (signature != spec.CDFH_SIGNATURE) {
//         return ReadError.NoCDHFSignatureAtOffset;
//     }
//
//     var start_byte = offset + 4;
//     var entries_read: u16 = 0;
//     var cds = try HeaderIterator(Cdfh).init(allocator, total_cds);
//     while (entries_read < total_cds) : (entries_read += 1) {
//         const cdfh = try Cdfh.newFromSlice(allocator, stream[start_byte..]);
//         start_byte += spec.CDHF_SIZE_NOV + cdfh.name_len + cdfh.extra_len + cdfh.comment_len;
//         try cds.insert(cdfh);
//     }
//     return cds;
// }
//
// fn parseAllLfh(allocator: Allocator, stream: []const u8, offset: usize, total_cds: u16) ReadError!HeaderIterator(Lfh) {
//     if (offset > stream.len or (stream.len - offset) < spec.LFH_SIZE_NOV) {
//         return ReadError.UnexpectedEOFBeforeCDHF;
//     }
//     const signature = std.mem.readInt(u32, stream[offset .. offset + 4][0..4], .little);
//     if (signature != spec.LFH_SIGNATURE) {
//         return ReadError.NoCDHFSignatureAtOffset;
//     }
//
//     var start_byte = offset + 4;
//     var entries_read: u16 = 0;
//     var cds = try HeaderIterator(Lfh).init(allocator, total_cds);
//     while (entries_read < total_cds) : (entries_read += 1) {
//         const cdfh = try Cdfh.newFromSlice(allocator, stream[start_byte..]);
//         start_byte += spec.LFH_SIZE_NOV + cdfh.name_len + cdfh.extra_len + cdfh.comment_len;
//         try cds.insert(cdfh);
//     }
//     return cds;
// }
//
// test "Find EOCD" {
//     const file = @embedFile("build.zip");
//     const allocator = testing.allocator;
//     const eocdr = try findEocdr(allocator, file);
//     defer eocdr.deinit();
// }
//
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
