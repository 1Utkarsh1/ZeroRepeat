# Native dependency provenance and verification

Initially recorded 2026-10-25; dependency verification refreshed 2026-10-30, Australia/Sydney. These are observed acquisition/build results, not performance measurements or a claim of bit-identical release binaries. The commands below correct the earlier optimization flag spelling; this installed Zig 0.17 accepts `safe`, not `ReleaseSafe`. Later 1 November verification passed 144 integrated tests and built/linked all Linux test binaries; see [repository-editing evidence](repository-editing.md). The 79-test results below remain the historical dependency checkpoint.

## SQLite

| Field | Pinned value |
|---|---|
| Version | 3.54.1 (`SQLITE_VERSION_NUMBER` 3054001) |
| Official acquisition | https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip |
| Archive size | 2,990,966 bytes |
| Archive SHA3-256 | `92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30` |
| Shipped source | `vendor/sqlite/sqlite3.c`, 9,582,521 bytes, unmodified |
| Source SHA-256 | `0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52` |
| Source SHA3-256 | `e2b869d3003b33c942b7dd7063604fbc53553e1b66609570df39b9b7b558ee81` |
| Embedded source identity | `2026-10-16 14:45:20 555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76` |
| Licensing | SQLite deliverable code is dedicated to the public domain; original source notice retained |

The official download page's machine-readable CSV was read directly and matched the archive filename, version, size, and SHA3-256 above. Node's built-in `crypto.createHash('sha3-256')` verified the downloaded archive before extraction. SHA-256 of the extracted archive member and vendored file matched exactly. No upstream script was executed.

Primary sources: [official download products and CSV contract](https://www.sqlite.org/download.html), [SQLite public-domain declaration](https://www.sqlite.org/copyright.html).

### Build contract

`build.zig` compiles the amalgamation once as a static library for the requested Zig target, then links the same build artifact into the shared core, executable and dependent test roots/helpers. It does not search for or link an installed `libsqlite3`.

The only explicit SQLite C flags are:

```text
-DSQLITE_ENABLE_FTS5
-DSQLITE_THREADSAFE=1
-DSQLITE_OMIT_LOAD_EXTENSION=1
```

The target's libc is linked. Linux also links libm for FTS5's math requirements. SQLite's generated header is embedded in the amalgamation; the small existing Zig C-ABI declarations in `src/db.zig` avoid generated first-party C wrappers and unavailable Zig 0.17 `@cImport` functionality.

`build.zig.zon` pins the Zig package identity and minimum version and includes `vendor/` in packaged inputs. Its dependency table is empty: a checkout contains the actual SQLite source and needs no SQLite download to build offline once a suitable Zig toolchain is installed.

### Why source is vendored

The first acquisition attempt used Zig 0.17's content-addressed package cache. In this environment, fetching the official ZIP produced hash `N-V-__8AAETTsABEodUZZFAyfdAm9hEyqBXuLw9pRSO0vFh9`, but replaying the generated cache archive retained an additional top-level directory and recomputed `N-V-__8AAETTsACt-JClKW4BKM6GIeql6to34i9WbXMgbXeI`. `zig build --fetch` correctly rejected the mismatch.

The official autoconf archive was also downloaded and verified: URL `https://www.sqlite.org/2026/sqlite-autoconf-3540100.tar.gz`, size 3,332,984 bytes, SHA3-256 `b6ced585c750916b1052667239a12c25a7ff34e7f06e1e6e01ecb0427657d9c4`. Its amalgamation bytes matched the ZIP member, but the package-cache root behavior repeated. That archive and its build scripts are not shipped or used.

This was an observed package acquisition/cache-path problem; both upstream archives had correct published checksums. Shipping the single unmodified C file avoids dependence on that behavior and keeps subsequent native/cross builds offline. The cost is approximately 9.6 MB of tracked third-party source; no custom SQLite implementation or runtime download fallback was added.

## Verification

Current successful commands ran from the ZeroRepeat repository with the verified local Zig 0.17.0 toolchain, outside cloud-managed Documents to avoid dataless toolchain placeholders:

```sh
zr_zig=/Users/utkarshrajput/.cache/zerorepeat/bootstrap/zig-aarch64-macos-0.17.0/zig
zr_cache=/Users/utkarshrajput/.cache/zerorepeat/zig-local
"$zr_zig" fmt --check build.zig build.zig.zon src
"$zr_zig" build test --cache-dir "$zr_cache" --summary all
"$zr_zig" build --cache-dir "$zr_cache" --prefix /Users/utkarshrajput/.cache/zerorepeat/build/native --summary all
/Users/utkarshrajput/.cache/zerorepeat/build/native/bin/zerorepeat doctor
otool -L /Users/utkarshrajput/.cache/zerorepeat/build/native/bin/zerorepeat
"$zr_zig" build -Dtarget=x86_64-linux-musl -Doptimize=safe --cache-dir "$zr_cache" --prefix /Users/utkarshrajput/.cache/zerorepeat/build/linux-x86_64-musl --summary all
file /Users/utkarshrajput/.cache/zerorepeat/build/linux-x86_64-musl/bin/zerorepeat
```

Observed results:

- macOS ARM64 Debug: build succeeded; **79/79 tests passed without reported allocator leaks** (76 shared-core tests, 2 CLI parser tests and 1 CLI subprocess regression), including the newly integrated provider/context modules.
- The native SQLite configuration regression queried version `3.54.1` and verified `ENABLE_FTS5`, `THREADSAFE=1`, and `OMIT_LOAD_EXTENSION` at runtime.
- `doctor` reported `SQLite 3.54.1; bundled native library` and passed its in-memory native storage, FTS5 search, and self-contained-context probe.
- `otool -L` listed only `/usr/lib/libSystem.B.dylib`; there was no dynamically linked SQLite library.
- Linux x86-64 musl `safe`: cross-build succeeded. `file` identified the output as a statically linked ELF x86-64 executable.

An earlier full test run exposed an allocator leak in a context stress test; arena-result ownership was fixed and the refreshed run passed. On 30 October, an initial compiler invocation blocked reading a dataless standard-library file before tests ran. Exact pinned archives were reacquired, checksums verified, original placeholder files preserved and source inputs recovered before the successful refreshed checks. See `../evidence/2026-10-30-verification.md` for raw reports, source hashes and recovery limits.

No Linux executable was run on the macOS host. Linux runtime behavior, thread-contention stress, final release reproducibility, a model server, and official benchmarks remain separate verification work. No Docker or Runpod resource was created for these checks.

## Native repository platform interfaces — 1 November

`src/repository_fs.zig` uses the pinned Zig standard library and target libc/kernel interfaces; no new package dependency was added. macOS uses descriptor-based metadata/ACL copying, extended attributes, atomic exchange and full file synchronization through the installed SDK ABI. Linux uses statx metadata, descriptor xattrs and rename exchange. Native metadata fixtures run on macOS; Linux variants build/link only. Relevant primary manuals, pinned source findings, portability limits and commands are recorded in [repository-editing research](repository-editing.md). Runtime feature availability still needs Linux execution and sandbox integration; a successful cross-build does not establish either.
