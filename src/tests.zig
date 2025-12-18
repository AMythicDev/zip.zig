const std = @import("std");
const zbench = @import("zbench");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const ZipArchive = @import("read.zig").ZipArchive;

test "Parse EOCD" {
    const dir = std.fs.cwd();
    const file = try dir.openFile("build.zip", .{ .mode = .read_only });
    var single_thread = std.Io.Threaded.init_single_threaded;
    const io = single_thread.io();
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    const allocator = testing.allocator;
    var archive = try ZipArchive.openFromFileReader(allocator, &r);
    defer archive.close();

    try testing.expect(archive.member_count != 0);
}

fn parseEOCDBenchmark(allocator: Allocator) void {
    const dir = std.fs.cwd();
    const file = try dir.openFile("build.zip", .{ .mode = .read_only });
    var single_thread = std.Io.Threaded.init_single_threaded;
    const io = single_thread.io();
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    var archive = try ZipArchive.openFromFileReader(allocator, &r);
    defer archive.close();

    try testing.expect(archive.member_count != 0);
}

test "Parse EOCD Benchmark" {
    var bench = zbench.Benchmark.init(std.testing.allocator, .{});
    defer bench.deinit();
    try bench.add("EOCD parse benchmark", parseEOCDBenchmark, .{});
    var buf: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();
}

pub fn loadZip(alloc: Allocator, comptime path: []const u8) !std.fs.File.Reader {
    const dir = std.fs.cwd();
    const file = try dir.openFile(path, .{ .mode = .read_only });
    const buf = try alloc.alloc(u8, 4096);

    var single_thread = std.Io.Threaded.init_single_threaded;
    const io = single_thread.io();
    const r = file.reader(io, buf);
    return r;
}

test "Parse CDFH" {
    const allocator = testing.allocator;
    var r = try loadZip(allocator, "build.zip");
    defer allocator.free(r.interface.buffer);
    var archive = try ZipArchive.openFromFileReader(allocator, &r);

    try testing.expect(archive.getFileByIndex(0) != null);
    try testing.expectEqual(archive.getFileByIndex(1), null);

    archive.close();
}

test "Read uncompressed data" {
    const allocator = testing.allocator;
    var r = try loadZip(allocator, "build.zip");
    defer allocator.free(r.interface.buffer);
    var archive = try ZipArchive.openFromFileReader(allocator, &r);
    defer archive.close();
    var file = archive.getFileByIndex(0).?;

    var buffer: [1000]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    _ = try file.decompressWriter(&writer);
}

test "Read flate compressed data" {
    const allocator = testing.allocator;
    var r = try loadZip(allocator, "readme.zip");
    defer allocator.free(r.interface.buffer);
    var archive = try ZipArchive.openFromFileReader(allocator, &r);
    defer archive.close();
    var file = archive.getFileByIndex(0).?;

    var buffer: [2000]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    _ = try file.decompressWriter(&writer);
}
