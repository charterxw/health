# Health / Pine handoff

**与用户交流一律用中文回复**（说明、总结、提问都用中文；代码、提交信息和代码注释保持英文）。

Read `docs/RESTORE.md` first for the source map, current versions, build commands,
and the distinction between source recovery and private data recovery.

- `ios/` is Pine's current native SwiftUI app, version 1.3.0 (10). Preserve bundle
  identifiers and Keychain/cache namespaces when updating an existing install.
- The approved home is the first card layout in `ios/DESIGN.md`: observation,
  recovery + steps, weekly activity rings and totals. Three tabs; no sleep tab.
  Sleep and the other health metrics live under recovery details.
- The 1.3 device build passed. Simulator runtime acceptance was cancelled at the
  user's request; do not report runtime, motion, or physical-device FPS as verified.
- `backend/` and `frontend/` match Pi release `dialog-diagnostics-20261118` at this
  snapshot. See `docs/provenance/raspberrypi-20261118.json` for byte hashes. The Pi's
  top-level working folder and `FRONTEND_RELEASE` marker can be stale; inspect the
  running containers and `CURRENT_RELEASE` before importing later changes.
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
