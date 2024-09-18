# zip.zig

A Zig library to work with [zip](https://en.wikipedia.org/wiki/ZIP_\(file_format\)) files.

This is an experimental library and not meant for production use. The only place where this has been used is
[zigverm](https://github.com/AMythicDev/zigverm).

## Adding it to your project
- Add `zip.zig` to your dependencies
```sh
zig fetch --save https://github.com/AMythicDev/zip.zig/archive/refs/tags/v[VERSION].tar.gz
```

- In your `build.zig`:
```zig
pub fn build(b: *std.Build) !void {
// Get the dependency into your build.zig
const zip = b.dependency("zip", .{});
// Add import to all your compile targets
test_exe.root_module.addImport("zip", zip.module("zip"));
```

## Basic Usage
### Open a zip file and list its members
```zig
    const file = try std.fs.File.openFile("myzip.zip", .{});

    const zipfile = try ZipArchive.openFromStreamSource(alloc, @constCast(&std.io.StreamSource{ .file = file }));

    var m_iter = zipfile.members.iterator();
    while (m_iter.next()) |i| {
        std.debug.print("{s}", i.key_ptr.*);
    }
```

## License
The project is licensed under Apache 2.0 License.

