# Packaging and releases

Chaperone ships four ways: a Homebrew tap, a MacPorts port, a release zip on GitHub, and `make install` from a clone. The tap and the port build from the tag's source tarball on the user's Mac, so the app they install is never quarantined.

| Channel | Where it lives |
|---|---|
| Homebrew | `Formula/chaperone.rb` in [dedalozzo/homebrew-chaperone](https://github.com/dedalozzo/homebrew-chaperone) |
| MacPorts | `macports/sysutils/chaperone/Portfile` here (see `macports/README.md`) |
| Release zip | an asset on each [GitHub release](https://github.com/dedalozzo/chaperone/releases), built with `make dist` |

## Cutting a release

1. Set the new version in `Info.plist`: `CFBundleShortVersionString`, and bump `CFBundleVersion`. Commit.
2. Tag and push: `git tag -a vX.Y.Z -m "Chaperone X.Y.Z" && git push origin main vX.Y.Z`.
3. Build the zip from the tagged tree: `make clean dist`. It prints the zip's SHA-256.
4. On github.com, create the release from the tag, attach `dist/Chaperone-X.Y.Z-arm64.zip`, and put its SHA-256 in the release notes.
5. Checksum the tag tarball (both the formula and the Portfile use it):
   ```sh
   curl -fsSL -o /tmp/chaperone.tgz https://github.com/dedalozzo/chaperone/archive/refs/tags/vX.Y.Z.tar.gz
   shasum -a 256 /tmp/chaperone.tgz
   openssl dgst -rmd160 -r /tmp/chaperone.tgz
   stat -f%z /tmp/chaperone.tgz
   ```
6. In the tap, update `url` and `sha256` in `Formula/chaperone.rb`. Commit and push.
7. Here, update `github.setup` (the version), `revision 0` and `checksums` in the Portfile, run `port lint --nitpick`, commit and push.

Every upgrade rebuilds the app, and the app is signed ad hoc, so users must remove Chaperone from Developer Tools and add it again. Say so in the release notes.
