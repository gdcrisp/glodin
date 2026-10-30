# Release checklist

## Prepare

1. Update the version, changelog, README examples and artifact names.
2. Use the pinned Odin compiler and stock Gleam; run `make check test docs package`.
3. Inspect the generated archive's metadata and source contents. Confirm licenses,
   guides, toolkit sources and declarations are included, with no native binaries,
   debug bundles, build caches or credentials.
4. Run the archive integration checks, a fresh consumer and the exported production
   shipment outside the source tree.
5. Push `main` with `jj git push --bookmark main` and require every CI matrix job
   to pass for that exact commit: Linux/macOS, arm64/x64, OTP 27/28/29.

## Publish

1. Check the release version is available on Hex and the repository is clean.
2. Set the immutable release tag with `jj tag set v0.1.0 -r main` and push it with
   `git push origin refs/tags/v0.1.0`. Jujutsu 0.39 cannot push tags itself.
3. Authenticate using `gleam hex authenticate` or a locally supplied
   `HEXPM_API_KEY`. Never put a key in source, logs, an issue or a chat.
4. From the tested release checkout, run `make package`, then
   `escript priv/glodin.escript publish --yes`. Stock Gleam uploads both the
   package and HexDocs. Native library authors use their generated wrapper.
5. Verify the public Hex metadata, versioned HexDocs pages and source links.
   Install the release into a fresh project using `gleam add glodin@0.1.0`,
   scaffold a NIF, edit it, and run the wrapper tests.
6. Publish the matching GitHub release with the verified archive and changelog.

If package publication succeeds but documentation fails, repair documentation
with `gleam docs publish` from the same tested sources. Do not silently replace
published package contents. Retire a broken release when necessary and publish
a new patch version after validation.

The capability guide distinguishes tested 0.1.0 interfaces from future exhaustive
Rustler parity work. Local results alone do not certify the platform matrix.
