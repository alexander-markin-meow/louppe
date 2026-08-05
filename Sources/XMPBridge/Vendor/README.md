# Vendored XMPCore source subset

Louppe compiles a narrow, static XMPCore target from reviewed source. It does
not build XMPFiles or any media-embedding handlers.

Pinned inputs:

- Adobe XMP Toolkit SDK revision
  `7093513bd3caaad29da01db0f275d88a39d6bcc2` (BSD 3-Clause)
- libexpat revision
  `654d2de0da85662fcc7644a7acd7c2dd2cfb21f0` (MIT, Expat 2.5.0)

The `XMPToolkit` tree contains the headers required by the exact `.cpp` source
manifest in `Package.swift`: the legacy XMPCore implementation, its common
interfaces, the macOS configuration header, Unicode/XML helpers, and MD5
helper. The `Expat` tree supplies the three parser `.c` files and their private
headers. `XMPToolkit/third-party/expat/lib` is the include-layout shim expected
by Adobe's source and is copied from the same pinned Expat revision.

`Package.swift` defines `BanAllEntityUsage=1` and the bridge installs a strict
XMPCore parse-error callback for every packet. Do not replace this target with
handwritten XML merging or broaden it to XMPFiles. When updating either input,
repeat the isolation proof, review the source manifest, update both revision
records and licenses, and rerun the packet and hostile-filesystem suites.

Complete license texts live in `ThirdPartyLicenses/` and are copied into every
app bundle. Release verification compares them in both the loose app and the
independently extracted archive.
