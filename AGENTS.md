# Health / Pine handoff

**与用户交流一律用中文回复**（说明、总结、提问都用中文；代码、提交信息和代码注释保持英文）。

Read `docs/RESTORE.md` first for the source map, current versions, build commands,
and the distinction between source recovery and private data recovery.

- `ios/` is Pine's current native SwiftUI app, version 1.4.0 (11). Preserve bundle
  identifiers and Keychain/cache namespaces when updating an existing install.
- The home is described in `ios/DESIGN.md` (总览): observation (the week's summary
  on Sunday evening) → today's goals (ring glyph + steps tile) → this week (day
  glyphs, activity total, strength index) → recovery / sleep / weight row. Three
  tabs; no sleep tab. Sleep and the other health metrics live under recovery details.
  Reading a detail pushes a page; only editing (goals, feelings, walks) uses a sheet.
- The 1.4 device Release build and all core checks passed in CI (iOS build run 36,
  commit 9730c71). It has not been run in a simulator or on a phone; do not report
  runtime, motion, or physical-device FPS as verified.
- `frontend/` matches Pi release `dialog-diagnostics-20261118`. `backend/` adds, after
  that release, exercise setup notes, the body log (girths, protein), feelings fields
  (soreness, stress, note) and home `extras`; the app degrades without them until the
  Pi is redeployed. See `docs/provenance/raspberrypi-20261118.json` for the release's
  byte hashes. The Pi's top-level working folder and `FRONTEND_RELEASE` marker can be
  stale; inspect the running containers and `CURRENT_RELEASE` before importing later changes.
- `ios/LegacyWebShell/` is historical source, excluded from the native targets.
- Keep generated muscle geometry, app icons, rest sound, catalogues, prompts,
  dependency locks and third-party notices. No downloaded vendor exercise media
  are required for a build.
- Never commit credentials, cookies, OAuth records, signing keys, health databases,
  real user reports, saved personal targets, or build caches. Design fixtures are
  synthetic and Debug-simulator-only. `work/` holds untracked local investigations.
- Do not run diagnostic scripts that log in, regenerate analyses, send Telegram
  messages, rotate passwords, install timers, or change production as part of a
  source check. `ops/` contains explicit host administration commands.

Useful isolated checks (see RESTORE.md for dependencies):

```sh
python3 ios/scripts/check-project.py
swift run --package-path ios --jobs 2 HealthCoreChecks
swift run --package-path ios --jobs 2 NativeCoreChecks
ALLOWED_HOSTS=testserver,localhost,127.0.0.1,backend PYTHONPATH=backend python -m unittest discover -s backend/tests -v
cd frontend && npm ci && npm test && npm run build
```

Use `backend/tests/` for automated backend tests. Top-level `backend/test_sleep.py`
is an old live-account diagnostic and must not be picked up as an isolated test.
