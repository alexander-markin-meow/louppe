# Automatic updates

Louppe uses Sparkle 2.9.4 for daily update checks, secure background downloads,
installation on quit, and the manual **Louppe → Check for Updates…** command.
Photographers can turn automatic checks and downloads on or off in
**Louppe → Settings…**.

## Security model

- The appcast is served over HTTPS from `appcast.xml` on `main`.
- Both the feed and update archive are signed with Sparkle's Ed25519 key.
- Louppe requires the signed feed and verifies the archive before extracting
  it. A changed or forged download is rejected.
- Only the public key is embedded in `Louppe.app`. The private key remains in
  the release owner's macOS Keychain under the account
  `com.alexandermarkin.louppe`.

The current public key is:

```text
ZT/Kv98/mVd/uo2iUyBb0Gj0ShZqZ+FdfthHBjyH86k=
```

Back up the private key somewhere encrypted and outside this repository. After
building once, locate Sparkle's key tool and export the key (substitute the
path printed by `find` if SwiftPM uses a different artifact folder):

```sh
find .build/artifacts -path '*/Sparkle/bin/generate_keys' -print

.build/artifacts/louppe/Sparkle/bin/generate_keys \
  --account com.alexandermarkin.louppe \
  -x /secure/offline/location/louppe-sparkle-private-key
```

Losing the private key means existing updater-enabled builds cannot accept a
normally signed update. Never commit or upload the exported private key.

Sparkle is fetched as a public binary with its official SHA-256 checksum.
`build_app.sh` disables SwiftPM's optional Keychain credential lookup, so
building Louppe neither needs nor requests access to a saved GitHub login.

## Release procedure

1. Confirm `VERSION` and the top `CHANGELOG.md` entry are final. The normal
   one-bump-per-release-cycle rule still applies.
2. Build the app and release archive:

   ```sh
   ./build_app.sh
   ```

3. Sign the archive and regenerate the signed feed:

   ```sh
   ./Scripts/prepare_update_feed.sh
   ```

4. Create GitHub release `v<MARKETING_VERSION>` and upload the exact generated
   `dist/Louppe.zip`. Do not recompress or replace it after the feed is made.
5. Commit and push the generated `appcast.xml`. Verify its enclosure URL
   downloads the GitHub release asset.
6. From the previous public Louppe version, choose **Check for Updates…** and
   complete one real update before announcing the release.

The archive name stays `Louppe.zip`; its versioned GitHub tag makes the URL
unique. `prepare_update_feed.sh` embeds only the current changelog entry,
creates no delta files, signs the archive reference, and signs the complete
feed.

## Local verification

`build_app.sh` preserves Sparkle's versioned framework symlinks, embeds it in
`Contents/Frameworks`, signs the complete app, and builds the same zip used for
GitHub. Useful checks:

```sh
codesign --verify --deep --strict dist/Louppe.app
otool -L dist/Louppe.app/Contents/MacOS/Louppe
plutil -p dist/Louppe.app/Contents/Info.plist

SPARKLE_TOOLS="$(find .build/artifacts -type d -path '*/Sparkle/bin' -print -quit)"
"$SPARKLE_TOOLS/sign_update" \
  --account com.alexandermarkin.louppe \
  --verify appcast.xml
```

The feed URL will not expose an unpublished local build. Automatic checks only
offer versions present in the committed, signed `appcast.xml`.
