import assert from "node:assert/strict";
import {
  generateKeyPairSync,
  randomBytes,
  verify as cryptoVerify,
} from "node:crypto";
import {
  mkdtemp,
  readFile,
  rm,
  stat,
} from "node:fs/promises";
import { afterEach, test } from "node:test";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  APNsClient,
  ActivityScheduler,
  EncryptedStateStore,
  RelayError,
  buildLiveActivityPayload,
  classifyAPNsResponse,
  createProviderJWT,
  createRelayHTTPRequestHandler,
  validateActivityInput,
} from "../server.mjs";

const fixtureURL = new URL("./fixtures/activity.json", import.meta.url);
const accessToken = "test-access-token-which-is-longer-than-32-bytes";
const temporaryDirectories = new Set();

async function fixture() {
  return JSON.parse(await readFile(fixtureURL, "utf8"));
}

function silentLogger() {
  return {
    debug() {},
    info() {},
    warn() {},
    error() {},
  };
}

class FakeTimers {
  constructor(nowMS = 1_720_000_000_000) {
    this.nowMS = nowMS;
    this.nextID = 1;
    this.tasks = new Map();
  }

  now = () => this.nowMS;

  setTimer = (operation, delay) => {
    const id = this.nextID;
    this.nextID += 1;
    this.tasks.set(id, {
      due: this.nowMS + Math.max(0, delay),
      operation,
    });
    return id;
  };

  clearTimer = (id) => {
    this.tasks.delete(id);
  };

  async advance(milliseconds) {
    const target = this.nowMS + milliseconds;
    while (true) {
      const dueTasks = [...this.tasks.entries()]
        .filter(([, task]) => task.due <= target)
        .sort((left, right) => left[1].due - right[1].due);
      if (dueTasks.length === 0) break;
      const [id, task] = dueTasks[0];
      this.tasks.delete(id);
      this.nowMS = task.due;
      await task.operation();
    }
    this.nowMS = target;
  }

  async jumpAndRunDue(milliseconds) {
    this.nowMS += milliseconds;
    while (true) {
      const dueTasks = [...this.tasks.entries()]
        .filter(([, task]) => task.due <= this.nowMS)
        .sort((left, right) => left[1].due - right[1].due);
      if (dueTasks.length === 0) break;
      const [id, task] = dueTasks[0];
      this.tasks.delete(id);
      await task.operation();
    }
  }
}

class FakeAPNsClient {
  constructor() {
    this.calls = [];
    this.responses = [];
  }

  async send(request) {
    this.calls.push(structuredClone(request));
    const response = this.responses.shift() ?? {
      status: 200,
      reason: "",
      accepted: true,
      invalidateToken: false,
      retryable: false,
    };
    return response;
  }

  close() {}
}

function makeScheduler(
  fakeAPNs = new FakeAPNsClient(),
  schedulerOptions = {},
) {
  const timers = new FakeTimers();
  const scheduler = new ActivityScheduler({
    APNsClient: fakeAPNs,
    logger: silentLogger(),
    now: timers.now,
    setTimer: timers.setTimer,
    clearTimer: timers.clearTimer,
    minimumUpdateIntervalMS: 0,
    ...schedulerOptions,
  });
  return { scheduler, timers, fakeAPNs };
}

function mockRequest({
  method,
  url,
  authorization,
  body,
}) {
  return {
    method,
    url,
    headers: authorization ? { authorization } : {},
    async *[Symbol.asyncIterator]() {
      if (body !== undefined) {
        yield Buffer.from(body);
      }
    },
  };
}

class MockResponse {
  constructor() {
    this.headers = {};
    this.statusCode = 0;
    this.body = Buffer.alloc(0);
  }

  setHeader(name, value) {
    this.headers[name.toLowerCase()] = value;
  }

  writeHead(statusCode, headers) {
    this.statusCode = statusCode;
    for (const [name, value] of Object.entries(headers)) {
      this.headers[name.toLowerCase()] = value;
    }
  }

  end(body) {
    this.body = Buffer.from(body ?? "");
  }

  JSON() {
    return JSON.parse(this.body.toString("utf8"));
  }
}

afterEach(async () => {
  for (const directory of temporaryDirectories) {
    await rm(directory, { recursive: true, force: true });
  }
  temporaryDirectories.clear();
});

test("creates an ES256 APNs provider token with a raw P-256 signature", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "P-256",
  });
  const token = createProviderJWT({
    teamID: "TEAM123456",
    keyID: "KEY1234567",
    privateKey,
    issuedAtSeconds: 1_720_000_000,
  });
  const [header, claims, signature] = token.split(".");
  assert.deepEqual(
    JSON.parse(Buffer.from(header, "base64url").toString("utf8")),
    { alg: "ES256", kid: "KEY1234567" },
  );
  assert.deepEqual(
    JSON.parse(Buffer.from(claims, "base64url").toString("utf8")),
    { iss: "TEAM123456", iat: 1_720_000_000 },
  );
  assert.equal(Buffer.from(signature, "base64url").length, 64);
  assert.equal(
    cryptoVerify(
      "sha256",
      Buffer.from(`${header}.${claims}`),
      { key: publicKey, dsaEncoding: "ieee-p1363" },
      Buffer.from(signature, "base64url"),
    ),
    true,
  );
});

test("validates the fixture and creates the exact ActivityKit state keys", async () => {
  const rawFixture = await fixture();
  const input = validateActivityInput(
    rawFixture,
    rawFixture.bundleID,
  );
  assert.throws(
    () => validateActivityInput(rawFixture, "com.example.other"),
    (error) =>
      error instanceof RelayError &&
      error.statusCode === 403 &&
      error.code === "topic_not_allowed",
  );
  const payload = buildLiveActivityPayload({
    event: "update",
    timestamp: 1_720_000_000,
    staleDate: 1_720_000_004,
    state: {
      line: input.cues[0].text,
      source: input.source,
      videoID: input.videoID,
      videoTitle: input.title,
      isPlaying: true,
      cueStartMS: 0,
      cueEndMS: 4_000,
      nextLine: input.cues[1].text,
      nextCueStartMS: 4_000,
      nextCueEndMS: 8_000,
      revision: 1,
    },
  });
  assert.equal(payload.aps.event, "update");
  assert.equal(payload.aps["stale-date"], 1_720_000_004);
  assert.deepEqual(
    Object.keys(payload.aps["content-state"]).sort(),
    [
      "cueEndMS",
      "cueStartMS",
      "isPlaying",
      "line",
      "nextCueEndMS",
      "nextCueStartMS",
      "nextLine",
      "revision",
      "source",
      "videoID",
      "videoTitle",
    ].sort(),
  );
  assert.ok(Buffer.byteLength(JSON.stringify(payload)) < 4_096);
});

test("schedules every cue with current and next state and ends naturally", async () => {
  const { scheduler, timers, fakeAPNs } = makeScheduler();
  const result = await scheduler.upsertActivity(
    "activity-fixture",
    await fixture(),
  );
  assert.equal(result.scheduledCueCount, 2);
  assert.equal(fakeAPNs.calls.length, 1);
  assert.equal(
    fakeAPNs.calls[0].payload.aps["content-state"].line,
    "First line",
  );
  assert.equal(
    fakeAPNs.calls[0].payload.aps["content-state"].nextLine,
    "Second line",
  );
  assert.equal(fakeAPNs.calls[0].priority, 10);
  assert.ok(fakeAPNs.calls[0].expiration > 1_720_000_000);

  await timers.advance(4_000);
  assert.equal(fakeAPNs.calls.length, 2);
  assert.equal(
    fakeAPNs.calls[1].payload.aps["content-state"].line,
    "Second line",
  );
  assert.equal(
    fakeAPNs.calls[1].payload.aps["content-state"].nextLine,
    "Third line",
  );

  await timers.advance(4_000);
  assert.equal(fakeAPNs.calls.length, 3);
  assert.equal(
    fakeAPNs.calls[2].payload.aps["content-state"].line,
    "Third line",
  );

  await timers.advance(4_000);
  assert.notEqual(fakeAPNs.calls.at(-1).payload.aps.event, "end");
  assert.equal(scheduler.activities.has("activity-fixture"), true);

  await timers.advance(5_000);
  assert.equal(fakeAPNs.calls.at(-1).payload.aps.event, "end");
  assert.equal(
    fakeAPNs.calls.at(-1).payload.aps["dismissal-date"],
    fakeAPNs.calls.at(-1).payload.aps.timestamp - 1,
  );
  assert.equal(scheduler.activities.has("activity-fixture"), false);
  await assert.rejects(
    scheduler.upsertActivity("activity-fixture", {
      ...(await fixture()),
      anchorTimestampMS: timers.now(),
    }),
    (error) =>
      error instanceof RelayError &&
      error.code === "activity_ended",
  );
  scheduler.shutdown();
});

test("autoplay PUT replaces a timeline during the natural-end grace period", async () => {
  const { scheduler, timers, fakeAPNs } = makeScheduler();
  const input = await fixture();
  await scheduler.upsertActivity("activity-autoplay", input);
  await timers.advance(12_000);
  assert.equal(scheduler.activities.has("activity-autoplay"), true);

  await scheduler.upsertActivity("activity-autoplay", {
    ...input,
    videoID: "autoplay-next-video",
    title: "Next Song",
    generation: input.generation + 1,
    anchorTimestampMS: timers.now(),
  });
  await timers.advance(5_000);
  assert.equal(scheduler.activities.has("activity-autoplay"), true);
  assert.equal(
    fakeAPNs.calls.some((call) => call.payload.aps.event === "end"),
    false,
  );
  scheduler.shutdown();
});

test("token rotation, pause, seek, and generation cancel old schedules", async () => {
  const { scheduler, timers, fakeAPNs } = makeScheduler();
  const playing = await fixture();
  await scheduler.upsertActivity("activity-clock", playing);

  const paused = {
    ...playing,
    pushToken: "b".repeat(64),
    position: 1,
    isPlaying: false,
  };
  await scheduler.upsertActivity("activity-clock", paused);
  assert.equal(fakeAPNs.calls.at(-1).pushToken, "b".repeat(64));
  assert.equal(
    fakeAPNs.calls.at(-1).payload.aps["content-state"].isPlaying,
    false,
  );
  const callCountWhilePaused = fakeAPNs.calls.length;
  await timers.advance(20_000);
  assert.equal(fakeAPNs.calls.length, callCountWhilePaused);

  await assert.rejects(
    scheduler.upsertActivity("activity-clock", {
      ...paused,
      generation: paused.generation - 1,
    }),
    (error) =>
      error instanceof RelayError &&
      error.statusCode === 409 &&
      error.code === "stale_generation",
  );

  await scheduler.upsertActivity("activity-clock", {
    ...paused,
    generation: paused.generation + 1,
    position: 8,
    isPlaying: true,
    anchorTimestampMS: timers.now(),
  });
  assert.equal(
    fakeAPNs.calls.at(-1).payload.aps["content-state"].line,
    "Third line",
  );
  await timers.advance(4_000);
  await timers.advance(5_000);
  assert.equal(fakeAPNs.calls.at(-1).payload.aps.event, "end");
  scheduler.shutdown();
});

test("an empty replacement timeline cancels the previous video schedule", async () => {
  const { scheduler, timers, fakeAPNs } = makeScheduler();
  const playing = await fixture();
  await scheduler.upsertActivity("activity-switch", playing);

  const holding = {
    ...playing,
    videoID: "replacement-video",
    title: "Replacement",
    position: 0,
    duration: 0,
    generation: playing.generation + 1,
    cues: [],
  };
  const result = await scheduler.upsertActivity(
    "activity-switch",
    holding,
  );
  assert.equal(result.scheduledCueCount, 0);
  assert.equal(
    fakeAPNs.calls.at(-1).payload.aps["content-state"].videoID,
    "replacement-video",
  );
  const callCount = fakeAPNs.calls.length;
  await timers.advance(30_000);
  assert.equal(fakeAPNs.calls.length, callCount);
  scheduler.shutdown();
});

test("classifies invalid, throttled, and server APNs responses", () => {
  assert.deepEqual(classifyAPNsResponse(410, "Unregistered"), {
    accepted: false,
    invalidateToken: true,
    retryable: false,
    providerTokenExpired: false,
    permanent: false,
  });
  assert.deepEqual(classifyAPNsResponse(429, "TooManyRequests"), {
    accepted: false,
    invalidateToken: false,
    retryable: true,
    providerTokenExpired: false,
    permanent: false,
  });
  assert.deepEqual(classifyAPNsResponse(503, "Shutdown"), {
    accepted: false,
    invalidateToken: false,
    retryable: true,
    providerTokenExpired: false,
    permanent: false,
  });
  assert.deepEqual(classifyAPNsResponse(413, "PayloadTooLarge"), {
    accepted: false,
    invalidateToken: false,
    retryable: false,
    providerTokenExpired: false,
    permanent: true,
  });
  assert.deepEqual(classifyAPNsResponse(403, "ExpiredProviderToken"), {
    accepted: false,
    invalidateToken: false,
    retryable: false,
    providerTokenExpired: true,
    permanent: true,
  });
});

test("retries 429 while useful and removes a token after APNs 410", async () => {
  const { scheduler, timers, fakeAPNs } = makeScheduler();
  fakeAPNs.responses.push(
    {
      status: 429,
      reason: "TooManyRequests",
      accepted: false,
      invalidateToken: false,
      retryable: true,
    },
    {
      status: 200,
      reason: "",
      accepted: true,
      invalidateToken: false,
      retryable: false,
    },
  );
  await scheduler.upsertActivity("activity-retry", await fixture());
  assert.equal(fakeAPNs.calls.length, 1);
  await timers.advance(500);
  assert.equal(fakeAPNs.calls.length, 2);
  assert.equal(scheduler.activities.has("activity-retry"), true);

  fakeAPNs.responses.push({
    status: 410,
    reason: "Unregistered",
    accepted: false,
    invalidateToken: true,
    retryable: false,
  });
  await scheduler.upsertActivity("activity-retry", {
    ...(await fixture()),
    generation: 8,
  });
  assert.equal(scheduler.activities.has("activity-retry"), false);
  scheduler.shutdown();
});

test("accepts a new client session with a reset generation and rejects retired sessions", async () => {
  const { scheduler, timers } = makeScheduler();
  const original = {
    ...(await fixture()),
    generation: 90,
    clientSessionID: "process-session-a",
  };
  await scheduler.upsertActivity("activity-session", original);
  await timers.advance(250);
  const restarted = {
    ...original,
    generation: 1,
    clientSessionID: "process-session-b",
    anchorTimestampMS: timers.now(),
  };
  const accepted = await scheduler.upsertActivity(
    "activity-session",
    restarted,
  );
  assert.equal(accepted.deliveryStatus, "accepted");
  await timers.advance(250);
  await assert.rejects(
    scheduler.upsertActivity("activity-session", {
      ...original,
      generation: 91,
      anchorTimestampMS: timers.now(),
    }),
    (error) =>
      error instanceof RelayError &&
      error.code === "stale_client_session",
  );
  scheduler.shutdown();
});

test("compensates position with anchorTimestampMS", async () => {
  const { scheduler, timers, fakeAPNs } = makeScheduler();
  await scheduler.upsertActivity("activity-anchor", {
    ...(await fixture()),
    position: 0,
    anchorTimestampMS: timers.now() - 4_500,
  });
  assert.equal(scheduler.activities.get("activity-anchor").position, 4.5);
  assert.equal(
    fakeAPNs.calls[0].payload.aps["content-state"].line,
    "Second line",
  );
  scheduler.shutdown();
});

test("rejects an implausibly old client anchor outside restart restoration", async () => {
  const { scheduler, timers } = makeScheduler();
  await assert.rejects(
    scheduler.upsertActivity("activity-stale-anchor", {
      ...(await fixture()),
      position: 1,
      anchorTimestampMS: timers.now() - 5 * 60_000,
    }),
    (error) =>
      error instanceof RelayError &&
      error.code === "stale_anchor",
  );
  scheduler.shutdown();
});

test("a stale client anchor does not cancel an existing APNs retry", async () => {
  const fakeAPNs = new FakeAPNsClient();
  fakeAPNs.responses.push(
    {
      status: 429,
      reason: "TooManyRequests",
      accepted: false,
      invalidateToken: false,
      retryable: true,
    },
    {
      status: 200,
      reason: "",
      accepted: true,
      invalidateToken: false,
      retryable: false,
    },
  );
  const { scheduler, timers } = makeScheduler(fakeAPNs);
  const input = await fixture();
  await scheduler.upsertActivity("activity-stale-retry", input);
  assert.equal(fakeAPNs.calls.length, 1);
  await assert.rejects(
    scheduler.upsertActivity("activity-stale-retry", {
      ...input,
      anchorTimestampMS: timers.now() - 5 * 60_000,
    }),
    (error) =>
      error instanceof RelayError &&
      error.code === "stale_anchor",
  );
  await timers.advance(1_000);
  assert.equal(fakeAPNs.calls.length, 2);
  scheduler.shutdown();
});

test("uses one timeline timer, emits long-gap state, and skips overdue cues", async () => {
  const { scheduler, timers, fakeAPNs } = makeScheduler();
  const timeline = {
    ...(await fixture()),
    duration: 12,
    cues: [
      { start: 0, end: 1, text: "First line" },
      { start: 5, end: 6, text: "Second line" },
      { start: 10, end: 12, text: "Third line" },
    ],
  };
  await scheduler.upsertActivity("activity-gap", timeline);
  assert.equal(timers.tasks.size, 1);
  await timers.advance(1_000);
  assert.equal(
    fakeAPNs.calls.at(-1).payload.aps["content-state"].line,
    "♪",
  );
  assert.equal(timers.tasks.size, 1);

  const callsBeforeStallRecovery = fakeAPNs.calls.length;
  await timers.jumpAndRunDue(9_500);
  assert.equal(fakeAPNs.calls.length, callsBeforeStallRecovery + 1);
  assert.equal(
    fakeAPNs.calls.at(-1).payload.aps["content-state"].line,
    "Third line",
  );
  assert.equal(timers.tasks.size, 1);
  scheduler.shutdown();
});

test("returns explicit delivery status and stops permanent APNs failures", async () => {
  const fakeAPNs = new FakeAPNsClient();
  fakeAPNs.responses.push({
    status: 403,
    reason: "TopicDisallowed",
    accepted: false,
    invalidateToken: false,
    retryable: false,
    permanent: true,
  });
  const { scheduler } = makeScheduler(fakeAPNs);
  const result = await scheduler.upsertActivity(
    "activity-rejected",
    await fixture(),
  );
  assert.equal(result.deliveryStatus, "rejected");
  assert.equal(result.apnsStatus, 403);
  assert.equal(result.apnsReason, "TopicDisallowed");
  assert.equal(scheduler.activities.has("activity-rejected"), false);
  scheduler.shutdown();
});

test("reports accepted, retrying, and rejected end delivery", async () => {
  const acceptedSetup = makeScheduler();
  await acceptedSetup.scheduler.upsertActivity(
    "activity-end-accepted",
    await fixture(),
  );
  const accepted = await acceptedSetup.scheduler.endActivity(
    "activity-end-accepted",
  );
  assert.equal(accepted.deliveryStatus, "accepted");
  assert.equal(accepted.ended, true);
  acceptedSetup.scheduler.shutdown();

  const retryAPNs = new FakeAPNsClient();
  const retrySetup = makeScheduler(retryAPNs);
  await retrySetup.scheduler.upsertActivity(
    "activity-end-retrying",
    await fixture(),
  );
  retryAPNs.responses.push({
    status: 429,
    reason: "TooManyRequests",
    accepted: false,
    invalidateToken: false,
    retryable: true,
  });
  const retrying = await retrySetup.scheduler.endActivity(
    "activity-end-retrying",
  );
  assert.equal(retrying.deliveryStatus, "retrying");
  assert.equal(retrying.ended, false);
  assert.equal(
    retrySetup.scheduler.activities.has("activity-end-retrying"),
    true,
  );
  await retrySetup.timers.advance(1_000);
  assert.equal(
    retrySetup.scheduler.activities.has("activity-end-retrying"),
    false,
  );
  retrySetup.scheduler.shutdown();

  const rejectedAPNs = new FakeAPNsClient();
  const rejectedSetup = makeScheduler(rejectedAPNs);
  await rejectedSetup.scheduler.upsertActivity(
    "activity-end-rejected",
    await fixture(),
  );
  rejectedAPNs.responses.push({
    status: 403,
    reason: "TopicDisallowed",
    accepted: false,
    invalidateToken: false,
    retryable: false,
    permanent: true,
  });
  const rejected = await rejectedSetup.scheduler.endActivity(
    "activity-end-rejected",
  );
  assert.equal(rejected.deliveryStatus, "rejected");
  assert.equal(rejected.ended, false);
  rejectedSetup.scheduler.shutdown();
});

test("DELETE tombstones reject out-of-order PUT until the fence expires", async () => {
  const { scheduler, timers, fakeAPNs } = makeScheduler();
  const input = await fixture();
  const missing = await scheduler.endActivity(
    "activity-delete-first",
    { establishTombstone: true },
  );
  assert.equal(missing.deliveryStatus, "not_found");
  await assert.rejects(
    scheduler.upsertActivity("activity-delete-first", input),
    (error) =>
      error instanceof RelayError &&
      error.code === "activity_ended",
  );
  assert.equal(fakeAPNs.calls.length, 0);

  await scheduler.upsertActivity("activity-put-first", input);
  await scheduler.endActivity(
    "activity-put-first",
    { establishTombstone: true },
  );
  await assert.rejects(
    scheduler.upsertActivity("activity-put-first", input),
    (error) =>
      error instanceof RelayError &&
      error.code === "activity_ended",
  );

  await timers.advance(16 * 60 * 1_000);
  const afterExpiry = await scheduler.upsertActivity(
    "activity-delete-first",
    {
      ...input,
      anchorTimestampMS: timers.now(),
    },
  );
  assert.equal(afterExpiry.deliveryStatus, "accepted");
  scheduler.shutdown();
});

test("refreshes an expired provider JWT once and emits exact Live Activity headers", async () => {
  const { privateKey } = generateKeyPairSync("ec", {
    namedCurve: "P-256",
  });
  const client = Object.create(APNsClient.prototype);
  Object.assign(client, {
    teamID: "TEAM123456",
    keyID: "KEY1234567",
    privateKey,
    logger: silentLogger(),
    now: () => 1_720_000_000_000,
    providerToken: "",
    providerTokenCreatedAt: 0,
  });
  const responseQueue = [
    { status: 403, reason: "ExpiredProviderToken", APNsID: "first" },
    { status: 200, reason: "", APNsID: "second" },
  ];
  const requests = [];
  client.sendRequest = async (headers, body) => {
    requests.push({ ...headers, body: Buffer.from(body) });
    return responseQueue.shift();
  };
  const result = await client.send({
    activityID: "activity-header",
    pushToken: "a".repeat(64),
    bundleID: "com.example.youtube.caption",
    payload: {
      aps: {
        timestamp: 1_720_000_000,
        event: "update",
        "content-state": { line: "test" },
      },
    },
    priority: 10,
    expiration: 1_720_000_060,
    collapseID: "ci-header",
  });
  assert.equal(result.accepted, true);
  assert.equal(requests.length, 2);
  assert.equal(requests[1][":path"], `/3/device/${"a".repeat(64)}`);
  assert.equal(requests[1]["apns-push-type"], "liveactivity");
  assert.equal(
    requests[1]["apns-topic"],
    "com.example.youtube.caption.push-type.liveactivity",
  );
  assert.equal(requests[1]["apns-priority"], "10");
  assert.equal(requests[1]["apns-expiration"], "1720000060");
  assert.equal(requests[1]["apns-collapse-id"], "ci-header");
  assert.match(requests[1].authorization, /^bearer /u);
});

test("enforces per-activity throttling, capacity, and 512 cue limit", async () => {
  const { scheduler } = makeScheduler(
    new FakeAPNsClient(),
    {
      minimumUpdateIntervalMS: 250,
      maxActivities: 1,
    },
  );
  const input = await fixture();
  await scheduler.upsertActivity("activity-limit-a", input);
  await assert.rejects(
    scheduler.upsertActivity("activity-limit-a", {
      ...input,
      generation: input.generation + 1,
    }),
    (error) =>
      error instanceof RelayError &&
      error.statusCode === 429 &&
      error.code === "activity_rate_limited" &&
      error.retryAfterMS === 250,
  );
  await assert.rejects(
    scheduler.upsertActivity("activity-limit-b", input),
    (error) =>
      error instanceof RelayError &&
      error.code === "activity_capacity_reached",
  );
  assert.throws(
    () => validateActivityInput({
      ...input,
      cues: Array.from(
        { length: 513 },
        (_, index) => ({
          start: index,
          end: index + 0.5,
          text: `line-${index}`,
        }),
      ),
      duration: 514,
    }),
    (error) =>
      error instanceof RelayError &&
      error.message.includes("at most 512"),
  );
  scheduler.shutdown();
});

test("encrypts durable state atomically and restores its timeline", async () => {
  const directory = await mkdtemp(
    join(tmpdir(), "caption-island-relay-test-"),
  );
  temporaryDirectories.add(directory);
  const statePath = join(directory, "relay.state");
  const stateStore = new EncryptedStateStore({
    path: statePath,
    key: randomBytes(32),
  });
  const firstAPNs = new FakeAPNsClient();
  const firstTimers = new FakeTimers();
  const firstScheduler = new ActivityScheduler({
    APNsClient: firstAPNs,
    logger: silentLogger(),
    now: firstTimers.now,
    setTimer: firstTimers.setTimer,
    clearTimer: firstTimers.clearTimer,
    minimumUpdateIntervalMS: 0,
    stateStore,
  });
  await firstScheduler.upsertActivity(
    "activity-durable",
    await fixture(),
  );
  firstScheduler.shutdown();

  const encrypted = await readFile(statePath, "utf8");
  assert.doesNotMatch(encrypted, /Fixture Song|First line|aaaaaaaa/u);
  assert.equal((await stat(statePath)).mode & 0o777, 0o600);
  assert.equal(stateStore.load().activities.length, 1);

  const secondAPNs = new FakeAPNsClient();
  const secondTimers = new FakeTimers(firstTimers.now() + 2_000);
  const secondScheduler = new ActivityScheduler({
    APNsClient: secondAPNs,
    logger: silentLogger(),
    now: secondTimers.now,
    setTimer: secondTimers.setTimer,
    clearTimer: secondTimers.clearTimer,
    minimumUpdateIntervalMS: 0,
    stateStore,
  });
  const restored = await secondScheduler.restoreFromStore();
  assert.deepEqual(restored, { restored: 1, discarded: 0 });
  assert.equal(
    secondScheduler.activities.get("activity-durable").position,
    2,
  );
  assert.equal(secondAPNs.calls.length, 1);
  assert.equal(secondTimers.tasks.size, 1);
  secondScheduler.shutdown();
});

test("restores an ending activity through its persisted tombstone", async () => {
  const directory = await mkdtemp(
    join(tmpdir(), "caption-island-ending-restore-test-"),
  );
  temporaryDirectories.add(directory);
  const stateStore = new EncryptedStateStore({
    path: join(directory, "relay.state"),
    key: randomBytes(32),
  });
  const firstAPNs = new FakeAPNsClient();
  const firstTimers = new FakeTimers();
  const firstScheduler = new ActivityScheduler({
    APNsClient: firstAPNs,
    logger: silentLogger(),
    now: firstTimers.now,
    setTimer: firstTimers.setTimer,
    clearTimer: firstTimers.clearTimer,
    minimumUpdateIntervalMS: 0,
    stateStore,
  });
  await firstScheduler.upsertActivity(
    "activity-ending-restore",
    await fixture(),
  );
  firstAPNs.responses.push({
    status: 429,
    reason: "TooManyRequests",
    accepted: false,
    invalidateToken: false,
    retryable: true,
  });
  const queued = await firstScheduler.endActivity(
    "activity-ending-restore",
    { establishTombstone: true },
  );
  assert.equal(queued.deliveryStatus, "retrying");
  assert.equal(
    stateStore.load().tombstones[0].activityID,
    "activity-ending-restore",
  );
  firstScheduler.shutdown();

  const secondAPNs = new FakeAPNsClient();
  const secondTimers = new FakeTimers(firstTimers.now() + 500);
  const secondScheduler = new ActivityScheduler({
    APNsClient: secondAPNs,
    logger: silentLogger(),
    now: secondTimers.now,
    setTimer: secondTimers.setTimer,
    clearTimer: secondTimers.clearTimer,
    minimumUpdateIntervalMS: 0,
    stateStore,
  });
  const restored = await secondScheduler.restoreFromStore();
  assert.deepEqual(restored, { restored: 1, discarded: 0 });
  assert.equal(
    secondAPNs.calls.at(-1).payload.aps.event,
    "end",
  );
  assert.equal(
    secondScheduler.activities.has("activity-ending-restore"),
    false,
  );
  assert.equal(
    secondScheduler.tombstones.has("activity-ending-restore"),
    true,
  );
  secondScheduler.shutdown();
});

test("HTTP API surfaces permanent APNs rejection as 424", async () => {
  const handler = createRelayHTTPRequestHandler({
    scheduler: {
      async upsertActivity(activityID) {
        return {
          activityID,
          deliveryStatus: "rejected",
          apnsStatus: 403,
          apnsReason: "TopicDisallowed",
        };
      },
    },
    accessToken,
    logger: silentLogger(),
  });
  const response = new MockResponse();
  await handler(mockRequest({
    method: "PUT",
    url: "/v1/activities/rejected-fixture",
    authorization: `Bearer ${accessToken}`,
    body: JSON.stringify(await fixture()),
  }), response);
  assert.equal(response.statusCode, 424);
  assert.equal(response.JSON().deliveryStatus, "rejected");
  assert.equal(response.JSON().apnsReason, "TopicDisallowed");
});

test("HTTP API requires bearer auth and accepts PUT and DELETE", async () => {
  const calls = [];
  const scheduler = {
    async upsertActivity(activityID, input) {
      calls.push({ method: "PUT", activityID, input });
      return {
        activityID,
        generation: input.generation,
        scheduledCueCount: input.cues.length - 1,
        isPlaying: input.isPlaying,
        deliveryStatus: "accepted",
      };
    },
    async endActivity(activityID) {
      calls.push({ method: "DELETE", activityID });
      return {
        activityID,
        ended: true,
        deliveryStatus: "accepted",
        apnsStatus: 200,
      };
    },
  };
  const handler = createRelayHTTPRequestHandler({
    scheduler,
    accessToken,
    logger: silentLogger(),
  });
  const URL = "/v1/activities/http-fixture";
  const unauthorizedResponse = new MockResponse();
  await handler(mockRequest({
    method: "PUT",
    url: URL,
    body: JSON.stringify(await fixture()),
  }), unauthorizedResponse);
  assert.equal(unauthorizedResponse.statusCode, 401);

  const acceptedResponse = new MockResponse();
  await handler(mockRequest({
    method: "PUT",
    url: URL,
    authorization: `Bearer ${accessToken}`,
    body: JSON.stringify(await fixture()),
  }), acceptedResponse);
  assert.equal(acceptedResponse.statusCode, 202);
  assert.equal(acceptedResponse.JSON().activityID, "http-fixture");

  const deletedResponse = new MockResponse();
  await handler(mockRequest({
    method: "DELETE",
    url: URL,
    authorization: `Bearer ${accessToken}`,
  }), deletedResponse);
  assert.equal(deletedResponse.statusCode, 202);
  assert.equal(deletedResponse.JSON().deliveryStatus, "accepted");
  assert.deepEqual(calls.map((call) => call.method), ["PUT", "DELETE"]);
});
