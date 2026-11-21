# Pine 1.4 — Native iOS

Pine now uses SwiftUI for login, overview, training, templates, exercises, records,
reports, observations and settings. The app target contains no WKWebView, React,
JavaScript bridge or remotely loaded page. Metric trends use Swift Charts; sleep stages and muscle maps use native Canvas
geometry. Muscle paths are converted from the current source geometry.

This redesign targets **iPhone 18 Pro in portrait**. Its three tabs are
**总览 / 训练 / 运动记录**. The standard-size overview fits one iPhone 18 Pro page. Sleep, HRV, resting
heart rate and saved observations are under the recovery-index detail. Sleep
is not a tab; larger text may scroll to preserve the complete content.
[DESIGN.md](DESIGN.md) records the supplied web references, Apple HIG sources,
page hierarchy, project-specific layout choices and actual acceptance results.
The interface uses system navigation/tab materials, semantic fonts and native
search, with opaque grouped cards for content.
Version 1.3 keeps the user's selected original card layout. Home refinements use
Emil Kowalski's design-engineering guidance: immediate local press feedback,
stable date identities and selection, short transitions for actual numeric
changes, and the system Reduce Motion preference. There is no launch choreography,
looping animation, animation dependency or delay before performing an action.
Longer observations get a larger compact summary; their complete text remains
in the existing observation detail.
Startup phase changes are observed by a dedicated SwiftUI View; the App owns
the store's lifetime. Isolated design previews prepare their cache before the
first frame instead of waiting for authentication or scene-activation callbacks.

The API baseline is the running Raspberry Pi release `dialog-diagnostics-20261118`.
See [the verified source/asset provenance](../docs/native-ios-baseline.md).
The existing server, accounts, edited templates and saved workouts are reused;
no server deployment is necessary for this client.

## Included

- Native account login, secure session-cookie storage in Keychain, server-side
  session revocation, authenticated retry and account-scoped offline caches.
  Passwords are never stored. Cross-origin HTTP redirects are rejected.
- Overview: actual record/device times, walking/step goal, server-computed recovery
  score and baseline, sleep stages, HRV/resting heart rate, weight, daily activity
  split, weekly rings, feelings, next-week goals and editable walk times.
- Current training round, optional E, remaining-work launch, company/home/posture
  template library, round linking and next-round confirmation.
- Template editing, per-set prescribed targets, edited-target history baselines,
  double progression, kg/lb conversion and custom exercise creation.
- Focused workout recording with native number keyboards that select all text,
  warmups, bodyweight/assistance, repetitions or duration, set feedback, fill-next,
  add/remove/replace/reorder, pause/resume, notes and rest countdowns. Any set can
  be corrected or unchecked from one set sheet; a just-checked set can be undone
  for five seconds; the rest panel shows the finished set with one-tap effort;
  each machine move keeps a standing setup note (server-backed).
- Lock Screen and Dynamic Island buttons (App Intents): complete the set shown,
  add 30 seconds, skip rest. They run in the app process and republish the activity.
- Atomic on-device draft deltas written before acknowledging edits, with full
  checkpoints encoded on a background queue. Existing account caches migrate
  without discarding records. Serial versioned synchronization retries pending
  edits while active; idle checks do not fetch or rewrite unchanged data.
  Explicit conflicts retain alternative copies and durable deletion markers.
- Completed reports, per-set details and feedback, comparable same-load repetition
  deltas, actionable offline review, existing server AI review, physiology/source
  selection, correction, repeat, save-as-template and confirmed online deletion.
  Today's reports add next steps (the other company/home half with a local
  reminder, posture, the next day of the round); moves open their lift history
  (best set, estimated 1RM or volume, with new records marked).
- Feelings with sore areas, stress and a note; girths and protein synced to the
  server (photos stay on the phone). Older servers keep the phone's copy.
- Read-only imported workout archives and stored morning/evening/weekly observations.
- Unified, date-grouped records with type, name/action and month filtering.
- Collapsible company/home training groups; sleep stages and recovery indicators
  under the overview's 睡眠与作息 detail.
- Existing native Live Activity, Dynamic Island, foreground rest chime and opt-in
  local rest notifications. Native state is driven directly from the saved draft.

Data files use iOS file protection and are excluded from device backup. Logout
requires pending synchronization and retained conflict copies to be handled, then
revokes the native session and removes that account's native cache.

## Build and install

Open `Health.xcodeproj`, select the shared **Health** scheme and an iPhone simulator,
or run:

```sh
bash ios/scripts/build.sh --simulator
bash ios/scripts/build.sh --unsigned-ipa
```

The script selects `/Applications/Xcode.app` without changing global developer
settings. Xcode 26 or newer is supported; this version is built using Xcode 27.2,
with an iOS 17 minimum. Device and simulator build caches are separate and Swift
compilation is limited to two jobs.

`build/Pine-1.3.0-10-unsigned.ipa` (also `build/Pine-unsigned.ipa`) is the unsigned device package. Import it into the existing
SideStore setup and keep `WorkoutWidget.appex`; signing is required before a phone
can install it. Bundle IDs remain `com.frankandpatrick.health` and `.workout`, subject
to the user's existing `Config/Local.xcconfig` override. Both display names remain
ASCII. Xcode signing can alternatively use the configured Personal Team.

**Upgrade:** first confirm the old app has synchronized its workout. Already saved
server records and the same account remain available after native login. Safari/
WebView-only unsynchronized drafts and browser login cookies are not automatically
imported. The old website storage is not erased by this client.

Create the source-only distribution with `python3 scripts/package-source.py`.
It writes `build/Pine-native-iOS-source.zip`, excluding signing overrides, build
caches, the legacy web shell, credentials and personal training data.

## Verification

From the repository root:

```sh
swift run --package-path ios --jobs 2 HealthCoreChecks
swift run --package-path ios --jobs 2 NativeCoreChecks
python3 ios/scripts/check-project.py
python3 ios/Tests/serve-fixtures.py
```

With the fixture server running, use **Product → Test**, or build for testing then
run the shared Health UI test suite on an iPhone simulator. Fixtures listen only
on `127.0.0.1:43189`. The app accepts the test endpoint only in simulator Debug
builds with a valid per-run UUID. The Release IPA always uses the HTTPS production
host. Tests do not use production credentials or create online workouts.

The UI suite checks native login/retry with no web views, metric sheets, actual set
completion/pause/finish/server save, offline restart/retry, version conflicts and
alternative copies, settings persistence and timed mobility. Screenshots are
attached to the Xcode result bundle.

The native core checks cover completion validation, rest ownership and clocks,
strength/mobility separation, progression eligibility, edited template baselines,
remaining-work presets, missing values, units, in-flight edits, disk encoding and
deletion reconciliation. Contract validation also generates sessions from all
15 current source programs and checks them with the production backend models.

For visual inspection, simulator Debug builds accept `HEALTH_DESIGN_PREVIEW=1`
and `HEALTH_DESIGN_SCREEN=home|training|records|sleep`. These screens use synthetic,
explicitly labelled data, disable all API requests and do not prepare an account
cache. The fixture payload and switch are compiled out of the device Release.
Regenerate fixtures using `python3 ios/scripts/make-design-fixtures.py` from this
source checkout. This does not fetch or copy production health records.
For the home acceptance pass, `HEALTH_DESIGN_BRIEF=long` chooses a longer synthetic
observation. `HEALTH_DESIGN_REDUCE_MOTION=1` exercises the home motion policy through
a separate fixture environment value; production always reads the actual system
preference. These flags require simulator Debug + design preview and are excluded
from the device Release.

To regenerate muscle geometry after the web source changes, use Python with
`fonttools==4.60.1` installed and run `python3 ios/scripts/make-muscle-paths.py`.
The generated native resource is committed; normal builds need no Python package
or network dependency.

## Service boundaries

Google Health OAuth account management opens the system browser; its browser
session is independent of native login. Return to Pine and refresh after changing
server authorization. This client continues using the existing Google Health
integration, and does not add HealthKit or watchOS.

Report-ready push remains on the existing Home Screen website or server Telegram
channel. Native rest reminders are local notifications. There is no APNs service
or remote Live Activity push in this version. iOS owns background suspension,
notification delivery and ActivityKit time limits. Unsynced changes retry while
Pine is open and on foreground return; the app does not claim continuous execution
when terminated. Real-device signing, Lock Screen delivery, Focus settings and
physical-phone keyboard/accessibility acceptance remain device checks.

## Previous validation: 1.2

Version 1.2.0 (9) device Release and simulator Debug/UI test bundle build with
Xcode 27.2. Ten timer/routing checks and fourteen training/persistence/performance
correctness checks pass. New checks cover old-cache migration, crash recovery
before checkpointing, newer edits racing older checkpoints, conflict copies,
tombstones, explicit null metadata, failed atomic writes, concurrent date
formatting and Live Activity payload identity.

The Mac Release microbenchmark uses 1,000 synthetic records and seven edits:
full-cache write median **315.53 ms**, incremental transaction median **1.62 ms**;
per-edit bytes **4,999,904 → 5,055**. This compares the old and new persistence
algorithms; it is **not an iPhone frame-rate or real-device responsiveness test**.
The raw samples are in `build/performance-1.2.json`.

Performance changes include property-specific Observation updates, prepared
completed-history/week projections, cached prior performance and timestamps,
off-main record timeline construction, lazy scrolling content, cached native
muscle paths with Canvas, and suppression of identical ActivityKit publications.

Release binary checks exclude the preview payload/switch and WebKit linkage;
the Live Activity extension is embedded. The targeted iPhone 18 Pro UI case passes (one case, zero failures): three tabs,
no sleep tab/WebView, the initial overview footer is tappable without scrolling,
training/records switching, and recovery → sleep → back. Actual native screenshots
are saved under `build/qa/Pine-1.2-*.png`. The full workout UI suite was not rerun.
Further verification is recorded in `build/VALIDATION.json` and DESIGN.md.
No physical-device frame-rate measurement, dark/large-text acceptance or
notification delivery test has been performed by this task.

## Validation: 1.3.0 (10)

- Device Release IPA, simulator Debug app and UI-test bundle compile successfully.
- All 24 Swift timer/routing/training/persistence checks pass; project and
  embedded Live Activity structure checks pass.
- The IPA contains version 1.3.0 (10) for both app and widget, and no preview
  fixture flags or WebView code in the device app binary.
- The user requested that simulator checking stop. The UI run was cancelled;
  no passing runtime, visual, motion, dark-mode or large-text result is claimed
  for this revision. The early blank launch frame is not an accepted screenshot.
- On-device gesture, interaction latency and frame-rate acceptance remain
  unmeasured. Version 1.2's storage/performance improvements are retained.

Install `build/Pine-1.3.0-10-unsigned.ipa` through the user's existing SideStore
signing flow. Source is packaged as `build/Pine-1.3.0-10-source.zip` and
`build/Pine-native-iOS-source.zip`. The production server and user data were
not changed.
