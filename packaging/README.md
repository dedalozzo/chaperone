# Packaging and releases

Chaperone ships three ways: a MacPorts port, a release zip on GitHub, and `make install` from a clone. The port builds from the tag's source tarball on the user's Mac, so the app it installs is never quarantined. There is no Homebrew formula, by choice.

| Channel | Where it lives |
|---|---|
| MacPorts | `macports/sysutils/chaperone/Portfile` here (see `macports/README.md`) |
| Release zip | an asset on each [GitHub release](https://github.com/dedalozzo/chaperone/releases), built with `make dist` |

## Cutting a release

1. Set the new version in `Info.plist`: `CFBundleShortVersionString`, and bump `CFBundleVersion`. Commit.
2. Tag and push: `git tag -a vX.Y.Z -m "Chaperone X.Y.Z" && git push origin main vX.Y.Z`.
3. Test, then build the universal zip from the tagged tree:
   ```sh
   make clean test
   make clean dist ARCH="arm64 x86_64"
   ```
   `make dist` prints the zip's SHA-256.
4. On github.com, create the release from the tag, attach `dist/Chaperone-X.Y.Z-universal.zip`, and put its SHA-256 in the release notes.
5. Checksum the tag tarball, which the Portfile uses:
   ```sh
   curl -fsSL -o /tmp/chaperone.tgz https://github.com/dedalozzo/chaperone/archive/refs/tags/vX.Y.Z.tar.gz
   shasum -a 256 /tmp/chaperone.tgz
   openssl dgst -rmd160 -r /tmp/chaperone.tgz
   stat -f%z /tmp/chaperone.tgz
   ```
6. Update `github.setup` (the version), `revision 0` and `checksums` in the Portfile, run `port lint --nitpick`, commit and push. Then send the same Portfile to MacPorts as a pull request to [macports-ports](https://github.com/macports/macports-ports) (`sysutils/chaperone/Portfile`, commit message `chaperone: update to X.Y.Z`).

Every upgrade rebuilds the app, and the app is signed ad hoc, so users must remove Chaperone from Developer Tools and add it again. Say so in the release notes.
