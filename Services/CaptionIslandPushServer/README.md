# Caption Island Push Server

This is a small, zero-dependency Node.js 20+ relay for ActivityKit Live
Activity update tokens. It keeps lyric cue schedules in memory and sends
`liveactivity` requests to APNs over HTTP/2, so Lock Screen and Always-On
updates do not depend on the YouTube process retaining foreground execution
priority. An optional AES-256-GCM state file allows schedules to survive relay
restarts while keeping ActivityKit tokens and lyrics encrypted at rest.

## Signing prerequisite

`pushType: .token` is not sufficient by itself. The installed IPA must be
signed by a paid Apple Developer team using:

- a host App ID controlled by that team, not `com.google.ios.youtube`;
- the Push Notifications capability and a provisioning-authorized
  `aps-environment` entitlement;
- a separately provisioned widget extension whose identifier is
  `<host bundle ID>.CaptionIslandWidget`; and
- an APNs signing key from the same team as the installed host application.

The `bundleID` sent to this relay must be the host identifier after signing.
The APNs topic is constructed as:

```text
<bundleID>.push-type.liveactivity
```

An entitlement inserted only with `ldid`, a free provisioning profile, or an
APNs key from a different team cannot authorize that topic.

## Runtime configuration

The server uses only Node built-ins. Keep the `.p8` file readable only by the
service account and never embed it in an IPA.

**Never commit a real `.env`, APNs `.p8`, `RELAY_ACCESS_TOKEN`,
`RELAY_STATE_KEY`, or relay state file.** The included `.gitignore` covers the
usual names, but repository and deployment-secret scanning are still
recommended. `.env.example` contains placeholders only; this service does not
automatically load `.env` files.

```sh
export APNS_TEAM_ID="YOURTEAMID"
export APNS_KEY_ID="YOURKEYID"
export APNS_PRIVATE_KEY_PATH="/run/secrets/AuthKey_YOURKEYID.p8"
export APNS_ENVIRONMENT="sandbox"
export APNS_BUNDLE_ID="com.example.youtube.caption"
export RELAY_ACCESS_TOKEN="$(openssl rand -hex 32)"
export PORT="8080"

# Strongly recommended for production:
export RELAY_STATE_PATH="/var/lib/caption-island/relay.state"
export RELAY_STATE_KEY="$(openssl rand -hex 32)"

npm start
```

`APNS_ENVIRONMENT` accepts `sandbox` or `production`. Development profiles use
the sandbox environment; distribution profiles use production.
`APNS_BUNDLE_ID` must exactly match the installed host identifier. The relay
rejects any different client-supplied bundle ID instead of allowing its APNs
key to be used with another topic.

`RELAY_STATE_PATH` and `RELAY_STATE_KEY` must be set together.
`RELAY_STATE_KEY` accepts a 64-character hex value or base64 that decodes to
exactly 32 bytes. State is written as an authenticated AES-256-GCM envelope via
a mode-`0600` temporary file and atomic rename. On startup the relay decrypts
the file, projects each playing timeline to the current wall clock, submits a
fresh current-state update, and restores its next event. Production mode logs a
warning if durable state is disabled.

The incoming API intentionally listens on `127.0.0.1`. Put it behind an HTTPS
reverse proxy and authenticate every device with a high-entropy bearer token.
For a multi-user deployment, add an enrollment service instead of distributing
one shared token. Prefer an APNs topic-specific key where available.

The health check does not require authentication:

```text
GET /healthz
```

## Register or update an activity

Use the ActivityKit update token emitted by
`activity.pushTokenUpdates`. Times in this API are media seconds.

```http
PUT /v1/activities/7E03810D-17A5-4D75-A50C-2D63BFB724EA
Authorization: Bearer <RELAY_ACCESS_TOKEN>
Content-Type: application/json
```

```json
{
  "pushToken": "0123456789abcdef...",
  "bundleID": "com.example.youtube.caption",
  "videoID": "eRQKUwDNR34",
  "title": "Precious Star Dreamer",
  "source": "LRCLIB",
  "position": 31.6,
  "isPlaying": true,
  "duration": 252,
  "generation": 4,
  "clientSessionID": "launch-1720000000000-68A8D441",
  "anchorTimestampMS": 1720000000123,
  "frequentPushesEnabled": true,
  "playbackRate": 1,
  "cues": [
    { "start": 11, "end": 15.8, "text": "First line" },
    { "start": 15.8, "end": 20.4, "text": "Second line" }
  ]
}
```

`playbackRate` is optional and defaults to `1`. `startTime`, `endTime`, and
`line` are accepted as aliases for `start`, `end`, and `text`. The client may
temporarily send `duration: 0` with an empty `cues` array while changing
videos; this cancels the previous cue schedule without ending and recreating
the Live Activity.

`anchorTimestampMS` is the Unix-millisecond instant at which `position` was
sampled. For a playing snapshot, the relay advances the supplied position by
the upload transit time before scheduling, avoiding a permanent network-delay
offset. Normal client requests accept at most 30 seconds of compensation;
older playing snapshots are rejected so a stale retry cannot rewind the relay
schedule. Encrypted restart restoration uses the full server-owned elapsed
interval. Older clients may omit the field, but synchronized clients should
always send it.

`clientSessionID` must remain stable for one app-process lifetime and change
after the app relaunches. A new session may restart `generation` at zero. The
relay remembers a bounded set of superseded sessions, so a delayed request from
an older process cannot overwrite the new clock. Older clients that omit the
field use a legacy session and retain the original monotonic-generation rule.

Every PUT is a complete clock snapshot:

- a changed token rotates the ActivityKit destination immediately;
- `isPlaying: false` cancels future cue and natural-end timers and publishes a
  paused state;
- resume or seek sends a new position and reschedules from that anchor;
- a lower `generation` receives HTTP 409;
- a lower generation is accepted after a genuinely new `clientSessionID`;
- requests from a previously superseded session receive HTTP 409;
- every timer also captures an internal version, so a same-generation clock
  correction still prevents old callbacks from sending;
- natural completion waits through a five-second, versioned autoplay grace
  period; a newer video PUT cancels it, otherwise the relay sends an ActivityKit
  `end` event with an immediate dismissal date and installs the same tombstone
  fence used by DELETE;
- every registration has an eight-hour server-side safety expiry, including
  paused or timeline-less activities, so an abrupt client termination cannot
  leave an in-memory schedule alive indefinitely.

The relay accepts at most 32 simultaneous activities, 512 cues per activity,
and a 1 MiB request body. Ordinary snapshots for the same activity are limited
to one every 250 ms; token rotation and a new client session bypass that
interval. Rate and capacity responses are HTTP 429 and include `retryAfterMS`
plus `Retry-After`.

The client should send a new PUT only for token rotation, play/pause, seek,
rate changes, video changes, background handoff, and occasional drift
correction. It must not upload the 0.75-second local sampling stream.

Without `RELAY_STATE_*`, schedules remain memory-only and must be resent after a
relay restart. With encrypted state enabled, the relay restores them
automatically. Use a process manager in either mode.

The scheduler keeps only one timeline-event timer per activity. When that timer
fires it recalculates the current media position instead of replaying every
missed callback; a delayed or temporarily frozen server therefore jumps
directly to the newest relevant line. A gap of at least three seconds emits a
`♪` state at the previous cue's end, followed by the next caption at its start.
Shorter gaps retain the previous line to avoid unnecessary push-budget use.

## End an activity

```http
DELETE /v1/activities/7E03810D-17A5-4D75-A50C-2D63BFB724EA
Authorization: Bearer <RELAY_ACCESS_TOKEN>
```

The request cancels queued cues and sends:

```json
{
  "aps": {
    "timestamp": 1720000000,
    "event": "end",
    "content-state": {
      "line": "Last line",
      "source": "LRCLIB",
      "videoID": "eRQKUwDNR34",
      "videoTitle": "Precious Star Dreamer",
      "isPlaying": false,
      "cueStartMS": 0,
      "cueEndMS": 0,
      "revision": 42
    },
    "dismissal-date": 1719999999,
    "relevance-score": 1
  }
}
```

The response reports the APNs outcome just like PUT: `accepted` confirms the
end event, `retrying` means the relay owns a queued retry, and `rejected`
returns HTTP 424. If the relay no longer has that activity, it returns
`deliveryStatus: "not_found"` with HTTP 200 because no server-side schedule
remains to clean up.

Every DELETE also creates a 15-minute Activity-ID tombstone. This rejects a PUT
that was already in flight but arrives after the end request, preventing an
ended lyric schedule from being recreated. Tombstones are bounded to 256 and
are included in the encrypted state file when persistence is enabled.

## APNs behavior

Each cue update contains the current and next line and sets `stale-date` to
the next cue's wall-clock boundary. Registration, playback clock correction,
pause/resume, seek, and end requests use priority `10`; predictable scheduled
cue boundaries use priority `5` to preserve Apple's limited high-priority
budget. Requests use:

```text
apns-push-type: liveactivity
apns-topic: <bundleID>.push-type.liveactivity
apns-priority: 5 or 10
apns-expiration: <cue end wall-clock time>
apns-collapse-id: ci-<activity hash>
authorization: bearer <ES256 provider JWT>
```

The provider JWT is cached for 50 minutes and the HTTP/2 connection is reused.
An `ExpiredProviderToken` response clears the cache and retries exactly once
with a newly signed JWT.
The relay retries network errors, HTTP 429, and 5xx responses only while that
cue remains useful. A newer revision cancels an older retry. HTTP 410 and
permanent token/topic/provider errors cancel the activity's remaining schedule
instead of repeating a request that cannot succeed.

Every successful PUT response reports one of:

```json
{
  "deliveryStatus": "accepted",
  "apnsStatus": 200
}
```

`deliveryStatus` may also be `retrying`, in which case `retryAfterMS` and the
temporary APNs reason are included. A permanent APNs rejection returns HTTP 424
with `deliveryStatus: "rejected"`, `apnsStatus`, and `apnsReason`; the mobile
client must not describe that response as a successful registration.

Logs are structured JSON. They include only the first 12 characters of a
SHA-256 token fingerprint; raw push tokens, bearer credentials, private keys,
titles, and lyric text are never logged.

APNs acceptance does not override system policy.
`NSSupportsLiveActivitiesFrequentUpdates` lets the user authorize a larger
budget, and `frequentPushesEnabled` only reports whether that authorization is
currently enabled. iOS still controls final Always-On rendering and may
throttle updates.

## Test

```sh
npm test
```

The `node:test` suite verifies ES256 JWT signatures and refresh, exact APNs
headers, the ActivityKit payload schema and size, single-event cue scheduling,
long gaps and delayed-event skipping, natural ending, token rotation,
pause/seek rescheduling, process-session generation resets, anchor-delay
compensation, rate/capacity limits, encrypted persistence and restart
restoration, APNs response classification, and bearer authentication for the
HTTP API.
