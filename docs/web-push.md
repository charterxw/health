# Workout report Web Push

The user chose Web Push for workout-ready messages. Existing Telegram analysis
messages are independent; this feature does not add Telegram training-ready
messages. iOS/iPadOS 16.4+ supports standards-based Web Push for Home Screen web
apps. Permission must be requested from a user tap. The UI provides **开启通知**
under the app header gear **设置**, and **关闭通知** for this device. Training
home and reports do not display notification settings.

A minimal standalone manifest and `/push-sw.js` support background notifications.
The worker has no fetch handler or page/API caches. Subscription registration and
VAPID public-key reads require the existing dashboard login. Subscription
endpoints must be HTTPS Apple/FCM/Mozilla push hosts, with valid P-256 public keys
and 16-byte authentication keys. Secret subscription URLs/keys are stored only
server-side and not logged. The browser retains only its subscription ID.

The server creates a persistent private P-256 VAPID key next to DB_PATH (normally
`/data/webpush-vapid.pem`, mode 0600). WEB_PUSH_PRIVATE_KEY_FILE can override it.
Key creation publishes complete files without replacing an existing key. Preserve
this file with the database/volume; changing it requires new browser subscriptions.
The pinned server library is pywebpush 2.5.0. Notifications are encrypted with
`aes128gcm` and signed with VAPID. The visible message is generic: no numerical
health metrics or workout names are included on the lock screen.

`workout_push_deliveries` is a persistent per-workout/per-subscription outbox.
The collector checks it every 30 seconds, independently of the browser. Eligibility
requires the chosen heart source, at least 90% of window minutes containing samples,
no gap over 90 seconds, and a cloud sample at/after the workout end. This means a
usable heart-rate report, not proof every optional activity metric is present.
Partial/missing/ambiguous heart data does not trigger a ready message.

Enabling a new subscription includes the latest completed workout (if within the
seven-day collection period), plus future workouts. Older history is not replayed.
An eligible report creates one delivery row. Claims use expiring leases; ordinary
polls/corrections/restarts do not send another copy after successful delivery.
Failures retry with increasing delay and respect provider Retry-After. HTTP 404/410
removes the expired subscription. Disabling unsubscribes both server and browser.
Deleting a workout removes its queued deliveries, and the worker rechecks its
status/window/readiness before sending. Notification tags also collapse repeated
messages for the same workout. As with other external push providers, a crash
between provider acceptance and the database acknowledgement can cause a retry;
exactly-once physical delivery is not guaranteed.

A tap navigates an existing same-origin window or opens
`/?workout=<UUID>#strength`. Only same-origin navigation is allowed. The app loads
the requested report even when it is outside the recent session list; deleted
reports show a missing/deleted message and do not resurrect local records.

Validation uses isolated SQLite, mocked provider HTTP, real encryption/signing,
DOM interactions and a VM for the worker. These checks are not an iPhone push
permission or lock-screen delivery test. Production can validate endpoints, key
persistence and deployed files before a device subscribes; actual device delivery
requires the user to grant iOS permission. A provider acceptance is not proof the
notification was displayed or read.

References checked 2026-11-08:

- [WebKit: Web Push for iOS/iPadOS Home Screen apps](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/)
- [pywebpush official repository](https://github.com/web-push-libs/pywebpush)
- [Google Health sync cadence and data availability](https://developers.google.com/health/data-types?hl=en)
- [Google Health iOS synchronization guidance](https://support.google.com/googlehealth/answer/14236618?co=GENIE.Platform%3DiOS&hl=en)
- [Apple: Background App Refresh and force quitting](https://support.apple.com/en-us/118408)

Google describes automatic synchronization about every 15 minutes when Bluetooth
is connected and the app can run in the background; opening the nearby app also
triggers synchronization. This is conditional, not a maximum end-to-end latency.
The API only has uploaded data. Background App Refresh, Bluetooth access, network,
iOS suspension, force quitting and low power modes can affect availability. The
server's retry cadence is separate from phone/device synchronization.
