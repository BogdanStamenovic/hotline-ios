# darwin-sdk-build

A throwaway repository with exactly one job: run `xtool sdk build` on a GitHub
macOS runner, where Xcode is already installed, and publish the resulting Darwin
Swift SDK bundle as an artifact.

It exists because Apple gates the `Xcode.xip` download behind an authenticated
browser login, and because unpacking that xip locally needs far more transient
disk than the machine this is for has. A macOS runner has both already.

It is public only so that macOS runner minutes are unmetered. It deliberately
contains **nothing else** — no addressing, no credentials, no application code.
