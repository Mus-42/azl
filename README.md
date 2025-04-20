# Almost a zip library

AZL implements small but usable subset of `.zip` spec.

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

Examples can be found in examples folder.

To run use:

```sh
zig build extract -- output_dir path/to/your/archive.zip
```

```sh
zig build compress -- path/to/your/folder compressed_folder.zip
```

## Limitations

In particular: no Zip64, no encryption, only deflate / store compression methods, no non-seekable streams support.

Aslo following assumption been made: ``End of central directory`` is located right at the end of the file. 
(true for most wild files but not required by the spec)
