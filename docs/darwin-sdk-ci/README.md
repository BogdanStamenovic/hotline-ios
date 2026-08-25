# Building the Darwin SDK on a macOS runner

`build-darwin-sdk.yml` is the workflow that produced the Darwin Swift SDK this
project builds against. It ran in a **throwaway public repo**
(`BogdanStamenovic/darwin-sdk-build`, created with his explicit permission).
Its 805 MB artifact is deleted and the repo is **archived**, but it is **not
deleted** -- that needs a scope this token does not have. One command from him
finishes it:

    gh auth refresh -h github.com -s delete_repo   # then: gh repo delete BogdanStamenovic/darwin-sdk-build --yes

It is harmless in the meantime: public, archived, 14 KB, two files, no
credentials. It is kept here because the
workflow is where five separate failures are encoded, and losing it would mean
rediscovering them.

## Why a macOS runner at all

`xtool sdk build` turns an `Xcode.app` into a Swift SDK bundle a **Linux** host
can cross-compile with. The conversion needs macOS; the result does not. Public
repos get free macOS minutes, so no money was spent — which mattered, because
spending needs his approval and this did not qualify for one.

**The runner already has Xcode.** No `.xip` download, no Apple ID at this stage.
That was the surprise: the step that looked like it would need his credentials
did not.

## What each fix in there is for

1. **`Contents/Resources/bin/xtool`, not `Contents/MacOS/xtool`.** The release
   asset is a SwiftUI *application*. Running the inner binary directly starts an
   app and blocks in `__CFRunLoopRun` forever — it does not parse arguments, so
   it never reports the error you actually made. The `Resources/bin` wrapper
   sets `XTL_CLI=1` and is the CLI. This cost about 90 minutes of silent runs.
2. **`sdk build <path> <output-dir>`, with the output directory.** Attempt one
   used the right subcommand and omitted the positional. Because of (1) that
   error was invisible, and the silence got misread as "wrong subcommand".
3. **`--arch x86_64` explicitly.** It is the architecture of the *Linux host the
   SDK is for*, not the runner's. The runner is arm64, so autodetection would
   have produced a bundle that silently did not fit archserver.
4. **`sdk install` is a no-op on macOS** — it prints "Skipping SDK install; the
   iOS SDK ships with Xcode on macOS" and exits 0. A green step that did
   nothing. Hence: **the step asserts on the artifact, not the exit code.**
5. **No `--transform` and no `timeout`.** macOS has BSD tar and no GNU
   coreutils. The workflow polls a background build instead.

## If it needs running again

Recreate a public repo, push these two files, `gh workflow run`. Roughly four
minutes; the artifact is ~771 MB packed, ~3.1 GB extracted, and retention was
set to 5 days deliberately.

Install it on Linux with **`swift sdk install <path>/darwin.artifactbundle`** —
*not* `xtool sdk install`, which on Linux expects an `Xcode.xip`. Then match the
toolchain to the SDK: Xcode 26.2 means Apple Swift 6.2, so Swift 6.2.3 for
Linux. A newer toolchain is rejected outright.
