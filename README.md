# lazily-zig
A Zig library for lazy evaluation with context caching...With FFI to use with other languages.

This project is still in early stages.
Will use similar semantics as [lazily-py](https://github.com/btakita/lazily-py).

The main use case is Zig libraries for cross-platform logic via FFI. Building dynamic libraries for Native Apps/Flutter + servers and WASM for browsers.

## Multi-threading

By default, lazily supports multi-threading using `Context.mutex`. The performance should be ok for most usages. A more efficient implementation will be implemented as needed.

To disable multi-threading, set the `-Dmulti_threading=false` build option.

## Example Usage

- [auth](./src/examples/auth/root.zig)
- [cells](./src/examples/cells/root.zig)
