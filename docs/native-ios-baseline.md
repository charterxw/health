# Native iOS migration baseline — 2026-11-18

The authoritative web/API baseline is the running Raspberry Pi release
`dialog-diagnostics-20261118`, captured over the existing `raspberry-cf` SSH route.
The older Mac source and the Pi's top-level working source were not used as the
web/API baseline.

- Backend image: `sha256:8794db63485a91c1bd0748fe99f3b973f0ee0561259553636a4071dfe806405a`.
- Frontend image: `sha256:d20edecf49e4dddaa3dde80b19f39ddb9a0cf7907e74d1dc5c7453f17bfd1d69`.
- Every non-cache file in the running `/app/app` matched the corresponding release
  source, by SHA-256.
- The active container's HTML referenced `index-Z0bnce8m.js` and `index-CjLPiyYA.css`.
  Those three active files matched the downloaded release's bytes. Older unreferenced
  assets in the container were not treated as the current UI.
- HTML SHA-256: `d911e56acd6ff24247d1650e4cf9959215608de5fee84d6237ada8249a6705d2`.
- JS SHA-256: `563003a56aa5a0a3b10d014c11618aa2be97c00a4f5dec804fa213e6ea3c4406`.
- CSS SHA-256: `434b9a3c9c47490b2ee85f5f9efe9ec18c77a153d5548e69f6d7e5022f6c9bd4`.

The private local snapshot is under `work/raspberrypi-20261118-163426/`:
`baseline.json`, the downloaded source archive, and `local-before-native.tar.gz`.
132 changed/new source files were brought into the Mac workspace. Unrelated local
documents and local-only signing configuration were retained. Credentials, live
SQLite data, OAuth files and runtime secrets were not downloaded. No server files,
containers, training records or notifications were changed by this migration.

The Pi's iOS source was an older 0.2 shell. The newer Mac Pine 0.4 shell was retained
as the native-system baseline: bundle IDs, ASCII display names, icons, rest chime,
Live Activity presentation and deep links. Its web controller files are archived
in `ios/LegacyWebShell/`, outside every build target and source distribution.

Native screens read the current `/api/home`, catalog, sessions, review, physiology
and archive interfaces. Programs and exercise metadata are fetched from the
server, so the user's edited templates are not replaced by bundled defaults.
The latest body-map geometry is converted to native paths, preserving the original
MIT notice; no SVG/JavaScript renderer is included.

The source catalog includes 15 newer company/home/supplemental/posture programs.
Native-generated sessions for every one of those programs have been accepted by
this exact baseline's production Pydantic Session and Template models, without
writing a database or contacting a cloud service.
