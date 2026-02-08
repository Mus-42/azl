# Almost a zip library

Custom, relatively small library for in-memory operations on `.zip` archives (and as deflate compressor/decompressor).

The library was created mostly for educational purposes and personal use.

Code is mostly untested.

## Usage

Add a dependency with

```sh
zig fetch --save git+https://github.com/Mus-42/azl#COMMIT_HASH

```

where `COMMIT_HASH` is hash of needed commit

and add to your build.zig this lines:

```zig
    const azl_dep = b.dependency("azl", .{});
    your_exe.root_module.addImport("azl", azl_dep.module("azl"));
```

## Examples

Code examples can be found in examples folder.

To run use:

```sh
zig build extract -- output_dir path/to/your/archive.zip
```

```sh
zig build compress -- path/to/your/folder compressed_folder.zip
```

## Limitations

In particular: no Zip64, no encryption, only deflate / store compression methods.

Slow. At least ~2X slower than ZLIB for decompression and even more for compression while providing a bit worse compression quality.

Also following assumption been made: ``End of central directory`` is located right at the end of the file. 
(holds true for the most of wild files but not acutally required by the spec)
