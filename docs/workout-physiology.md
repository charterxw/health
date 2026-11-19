# Workout-window Google Health data

Strength workouts already persist physical `started_at` and `ended_at` in UTC,
with the workout's IANA timezone for display. Completion now atomically enqueues
health collection in `strength_physiology`. Heart-rate association does not
require Google Health to create an exercise session. It also does not establish
that Air's sampling rate is identical in every device mode; the observed sample
spacing and gaps are reported instead.

## What the report contains

- Raw heart-rate samples in `[started_at, ended_at)` from the Google/Fitbit
  wearable data-source family. All API pages are read. Invalid samples, duplicate
  samples and conflicting values at the same source/timestamp are handled by the
  existing recorder normalizer. Multiple sources require a choice; they are not
  combined into one heart-rate trace.
- Sample mean, minimum, maximum, sample count, minutes containing samples, and
  largest gap including the window edges. Mean is an arithmetic **sample** mean,
  not an inferred continuous/time-weighted value. The chart uses minute means
  and leaves missing minutes blank. No heart-rate zones or diagnostic conclusions
  are invented.
- Reconciled wearable steps and active energy over the exact physical window.
  Both have approximately one-minute storage resolution. Energy is a device
  estimate; a rollup value of zero is distinct from an absent value.
- If already cached, local-day sleep, HRV and resting heart rate, explicitly
  labeled daily recovery context. These are not workout measurements; HRV is not
  calculated from BPM values. Fetching this report does not invoke an AI model.

The window includes rests and pauses. The displayed active duration continues to
subtract accumulated pauses. Existing strength sets only have completion times,
so this feature does not infer set starts, per-set physiology or heart-rate
recovery after a set. Sensor cache/source selection do not enter the versioned
strength document or browser localStorage.

## Delayed synchronization

The server scheduler checks for due jobs every 30 seconds, processing at most
three workouts per invocation. A persisted ten-minute lease prevents overlapping
workers from collecting the same window. A response only writes if its lease
and start/end still match; discarding or changing the end invalidates an old
in-flight response. A worker restart can reclaim an expired lease. Recent
completed workouts (up to 200 from the preceding seven days) are backfilled at
startup without rewriting their documents.

After each ordinary empty/partial result, retry spacing increases with age:

| Age since end | Retry spacing |
| --- | --- |
| First 15 minutes | 1 minute |
| 15 minutes–2 hours | 5 minutes |
| 2 hours–1 day | 30 minutes |
| 1–3 days | 2 hours |
| 3–7 days | 6 hours |

A well-covered selected heart source (at least 90% of minutes and no gap over
90 seconds), a cloud sample at/after the workout end, and nonmissing activity
metrics reduce checks to six-hour corrections until the workout is one day old.
This is a polling heuristic, not proof that no additional data can arrive.
Authorization/permission failures and HTTP 429 use 30-minute backoff. Errors keep
previously successful values. OAuth refreshes are serialized across event loops,
and token-file replacement is atomic. Manual refresh queues a fetch, respects an
in-flight lease and a 30-second cooldown, and works after the seven-day horizon.
Unsupported windows (zero length or over 24 hours) remain saved without an API
request.

The phone polls **our cache** only while the report is visible and saved on the
server, every 15 seconds while pending or 60 seconds when ready. Leaving the page
stops this polling but does not stop server collection. Returning from Google
Health immediately reads the cache again. No service worker, notification or
phone background execution is required for server retries.

## What can and cannot trigger an Air upload

Google's iOS guidance says devices sync throughout the day and when the app is
opened near the device. Allow Google Health Bluetooth access and Background App
Refresh. If cloud data is still missing, open Google Health near Air and pull
down to sync, then return and use **重新获取**. The report includes these steps.
The report first waits for an automatic cloud collection result. It offers
**打开 Google Health 同步** only after that result is empty, partial or fails. A
queued/in-flight first attempt, a ready report, source selection, authorization
issues and unsupported windows do not show this fallback. A stored heart-rate
fetch timestamp or persisted collection errors mark a finished result; the job
attempt counter alone is not sufficient because it advances before the API
responds. Subsequent retries keep an existing fallback visible until data is ready.
The fallback uses the documented Universal Link
`https://www.fitbit.com/in-app/today`, directly in a user-tapped HTTPS anchor.
This opens Today in an installed app; iOS may otherwise show a web fallback.
No redirect, custom scheme, automatic navigation or invented sync command is used.
Returning from that link queues a fresh cloud check (subject to the existing
30-second cooldown), while normal cache polling and server retries continue.
This is the fallback when iOS background syncing is delayed; a backend API
request cannot force the phone's Bluetooth upload. Opening the app is not proof
that synchronization finished. Actual native handoff still requires an iPhone test.
For someone who wants a predictable routine, an iOS Shortcut using **Open App →
Google Health** at a chosen time or gym arrival can reduce the manual step, but
it is not installed/configured by this feature and cannot guarantee background
BLE sync.

A Google Health webhook can eventually replace most polling once a public
subscriber endpoint, Google Cloud subscriber/service-account configuration,
endpoint authentication and notification-signature verification are configured.
It only notifies after cloud data exists, so it cannot wake the phone or remove
this upload dependency. This release retains existing host access controls and
does not expose a webhook endpoint or claim a subscription has been registered.

## Validation and sources

Live read-only probes with the existing account returned physical heart-rate
samples and nonmissing steps/active-energy rollup fields. No new OAuth scopes
were needed. Unit/DOM tests use isolated databases and mocked external calls;
fixtures never create production workouts. Native iPhone rendering is not
simulated by DOM tests.

Primary references checked 2026-11-08:

- [Google Health physical-time and data-source filtering](https://developers.google.com/health/filters)
- [Point resources, including HeartRate](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints)
- [Physical-time rollUp](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/rollUp)
- [Data types, scopes and storage resolution](https://developers.google.com/health/data-types)
- [Steps rollup value](https://developers.google.com/health/reference/rest/v4/StepsRollupValue)
- [Active energy rollup value](https://developers.google.com/health/reference/rest/v4/ActiveEnergyBurnedRollupValue)
- [Google Health iOS sync guidance](https://support.google.com/googlehealth/answer/14236618?co=GENIE.Platform%3DiOS&hl=en-GA)
- [Official iOS Universal Links and Android App Links](https://developers.google.com/health/universal-app-links)
- [Webhooks and subscriber setup](https://developers.google.com/health/webhooks)
- [API rate limits](https://developers.google.com/health/rate-limits)
