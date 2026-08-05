# XMPCore integration record

This record began as the Phase-0 isolation proof for
`XMP_INTEROPERABILITY.md`. Phase 5 promotes the reviewed parser into the
shipping executable as a minimal audited source target. The original proof is
retained independently under `Prototypes/XMPBridgeProof`.

## Reviewed dependencies

| Component | Repository | Pinned revision | License |
|---|---|---|---|
| Adobe XMP Toolkit SDK / XMPCore | `https://github.com/adobe/XMP-Toolkit-SDK` | `7093513bd3caaad29da01db0f275d88a39d6bcc2` | BSD 3-Clause |
| Expat 2.5.0 | `https://github.com/libexpat/libexpat` | `654d2de0da85662fcc7644a7acd7c2dd2cfb21f0` | MIT |

The Adobe revision was the `main` tip reviewed on 2026-08-05. Its last commit
was dated 2025-11-03. Adobe's checkout declares Expat 2.5.0 as XMPCore's XML
parser dependency; the Expat revision above is the commit referenced by the
`R_2_5_0` tag.

The complete license texts are retained in
`ThirdPartyLicenses/XMPCore-BSD-3-Clause.txt` and
`ThirdPartyLicenses/Expat-MIT.txt`. Any future source or binary distribution
must continue to reproduce them.

## Production distribution decision

Louppe uses the minimal audited source approach rather than an opaque binary
artifact. `Sources/XMPBridge/Vendor/` contains the legacy XMPCore and Expat
header/source subset supporting the exact source manifest in `Package.swift`.
Only the files enumerated by that manifest are compiled; `XMPFiles` and all
media-embedding handlers are excluded from the build. The target therefore
builds for the same architecture and current macOS SDK as the Louppe
executable, with no separately downloaded runtime library.

`Sources/XMPBridge/Vendor/README.md` records the subset layout and update
procedure. `build_app.sh` copies both complete license texts into the app, and
`Scripts/verify_release.sh` compares them independently in the loose and
archived bundles.

## What the proof establishes

`Scripts/run_xmp_bridge_proof.sh` builds only the legacy XMPCore metadata API,
Expat, a narrow C bridge implemented in Objective-C++, and a Swift runner. It
does not build XMPFiles because Louppe will never embed metadata in media.
The build explicitly enables XMPCore's `BanAllEntityUsage` guard; Adobe's
source defaults that guard off, which is unsuitable for untrusted sidecars.
The bridge also installs an error callback that refuses XMPCore's default
"recover and return a partial packet" behavior for malformed XML.

The runner covers synthetic, non-copyrighted packets shaped for Universal
XMP, Lightroom Classic, Adobe Bridge, Capture One, and darktable. Together
they exercise:

- unknown namespaces and custom properties;
- custom `xmp:Label` text;
- flat and hierarchical keyword arrays;
- localized values and qualifiers;
- Adobe Camera Raw settings;
- darktable history, blend, and multi-color data;
- a writable packet wrapper with padding;
- malformed XML rejection.

For every valid fixture, the proof parses and serializes without losing the
sentinel foreign values, applies a typed Louppe rating/color/decision update,
reparses the result, verifies the four owned properties, and then repeats the
merge against its own output. The malformed fixture must fail.

Run it with exact local checkouts:

```sh
./Scripts/run_xmp_bridge_proof.sh \
  /path/to/XMP-Toolkit-SDK \
  /path/to/libexpat
```

The script refuses different revisions. It uses the selected current Apple
toolchain directly, preferring the current full-Xcode SDK when it is installed,
and retains its temporary build folder so the resulting objects and executable
can be inspected.

## Findings carried into production

- XMPCore is a suitable semantic parser/serializer and exposes the operations
  Louppe needs without XMPFiles.
- Production builds must keep `BanAllEntityUsage=1` and retain the malicious
  DOCTYPE fixture. The reviewed Adobe source otherwise defaults the guard off.
  Every parse must also install the strict callback: without it, recoverable
  XML failures can return a partial packet instead of throwing.
- Adobe does not publish a SwiftPM package. Its current checkout plus Expat is
  roughly 78 MiB before build products, so silently vendoring the whole SDK is
  not an acceptable integration step.
- XMPCore serialization is semantically stable, not byte-identical. Foreign
  fields survive, while formatting, prefix placement, and padding layout can
  change. File-level CAS must therefore continue to compare original raw
  bytes, while post-write verification must compare intended XMP semantics.
- The production bridge exposes only typed profile mappings, semantic
  verification, and property inspection. Swift owns planning, exact paths,
  conflict reporting, bounded reads, CAS, and durable publication.
- An existing custom `xmp:Label` without Louppe provenance cannot be removed
  unless a future confirmation explicitly authorizes it.
- Extension-qualified application packets are resolver outputs for unchanged
  transfer only. The merge bridge is used solely for the canonical stem XMP.
