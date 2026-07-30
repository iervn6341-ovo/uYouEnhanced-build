import http from "node:http";
import http2 from "node:http2";
import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createPrivateKey,
  randomBytes,
  sign as cryptoSign,
  timingSafeEqual,
} from "node:crypto";
import {
  chmodSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, basename, join } from "node:path";
import { pathToFileURL } from "node:url";

const MAX_REQUEST_BYTES = 1024 * 1024;
const MAX_APNS_PAYLOAD_BYTES = 3_900;
const MAX_CUES = 512;
const MAX_ACTIVITIES = 32;
const MAX_TOMBSTONES = 256;
const MAX_DURATION_SECONDS = 8 * 60 * 60;
const APNS_REQUEST_TIMEOUT_MS = 10_000;
const PROVIDER_TOKEN_LIFETIME_MS = 50 * 60 * 1_000;
const ACTIVITY_SAFETY_EXPIRY_MS = 8 * 60 * 60 * 1_000;
const ACTIVITY_TOMBSTONE_TTL_MS = 15 * 60 * 1_000;
const MIN_ACTIVITY_UPDATE_INTERVAL_MS = 250;
const MAX_CLIENT_TRANSIT_COMPENSATION_MS = 30_000;
const NATURAL_END_GRACE_MS = 5_000;
const GAP_STATE_THRESHOLD_SECONDS = 3;
const EVENT_EPSILON_SECONDS = 0.025;
const RETRY_DELAYS_MS = [500, 1_000, 2_000, 4_000, 8_000];
const STATE_AAD = Buffer.from("caption-island-relay-state-v1", "utf8");

export class RelayError extends Error {
  constructor(
    statusCode,
    message,
    code = "invalid_request",
    { retryAfterMS } = {},
  ) {
    super(message);
    this.name = "RelayError";
    this.statusCode = statusCode;
    this.code = code;
    this.retryAfterMS = retryAfterMS;
  }
}

function requiredEnvironmentValue(environment, name) {
  const value = environment[name]?.trim();
  if (!value) {
    throw new Error(`Missing required environment variable ${name}`);
  }
  return value;
}

export function loadConfig(environment = process.env) {
  const APNsEnvironment = requiredEnvironmentValue(
    environment,
    "APNS_ENVIRONMENT",
  ).toLowerCase();
  if (!["sandbox", "production"].includes(APNsEnvironment)) {
    throw new Error("APNS_ENVIRONMENT must be sandbox or production");
  }

  const portText = environment.PORT?.trim() || "8080";
  const port = Number(portText);
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
    throw new Error("PORT must be an integer between 1 and 65535");
  }

  const accessToken = requiredEnvironmentValue(
    environment,
    "RELAY_ACCESS_TOKEN",
  );
  if (Buffer.byteLength(accessToken, "utf8") < 32) {
    throw new Error("RELAY_ACCESS_TOKEN must contain at least 32 bytes");
  }
  const bundleID = requiredEnvironmentValue(
    environment,
    "APNS_BUNDLE_ID",
  );
  if (
    !/^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$/u.test(
      bundleID,
    )
  ) {
    throw new Error("APNS_BUNDLE_ID must be a valid bundle identifier");
  }

  const statePath = environment.RELAY_STATE_PATH?.trim() || "";
  const rawStateKey = environment.RELAY_STATE_KEY?.trim() || "";
  if (Boolean(statePath) !== Boolean(rawStateKey)) {
    throw new Error(
      "RELAY_STATE_PATH and RELAY_STATE_KEY must be configured together",
    );
  }
  const stateKey = rawStateKey ? decodeStateKey(rawStateKey) : null;

  return {
    teamID: requiredEnvironmentValue(environment, "APNS_TEAM_ID"),
    keyID: requiredEnvironmentValue(environment, "APNS_KEY_ID"),
    privateKeyPath: requiredEnvironmentValue(
      environment,
      "APNS_PRIVATE_KEY_PATH",
    ),
    APNsEnvironment,
    bundleID,
    accessToken,
    port,
    statePath,
    stateKey,
  };
}

function decodeStateKey(rawValue) {
  let key;
  if (/^[0-9a-f]{64}$/iu.test(rawValue)) {
    key = Buffer.from(rawValue, "hex");
  } else {
    try {
      key = Buffer.from(rawValue, "base64");
    } catch {
      key = Buffer.alloc(0);
    }
  }
  if (key.length !== 32) {
    throw new Error(
      "RELAY_STATE_KEY must encode exactly 32 bytes (64 hex characters or base64)",
    );
  }
  return key;
}

export class EncryptedStateStore {
  constructor({ path, key }) {
    if (!path || !Buffer.isBuffer(key) || key.length !== 32) {
      throw new Error("EncryptedStateStore requires a path and a 32-byte key");
    }
    this.path = path;
    this.key = Buffer.from(key);
  }

  load() {
    let encoded;
    try {
      encoded = readFileSync(this.path, "utf8");
    } catch (error) {
      if (error?.code === "ENOENT") {
        return { version: 1, activities: [], tombstones: [] };
      }
      throw error;
    }
    const envelope = JSON.parse(encoded);
    if (
      envelope?.version !== 1 ||
      envelope.algorithm !== "aes-256-gcm" ||
      typeof envelope.iv !== "string" ||
      typeof envelope.tag !== "string" ||
      typeof envelope.ciphertext !== "string"
    ) {
      throw new Error("Relay state envelope is invalid");
    }
    const decipher = createDecipheriv(
      "aes-256-gcm",
      this.key,
      Buffer.from(envelope.iv, "base64"),
    );
    decipher.setAAD(STATE_AAD);
    decipher.setAuthTag(Buffer.from(envelope.tag, "base64"));
    const plaintext = Buffer.concat([
      decipher.update(Buffer.from(envelope.ciphertext, "base64")),
      decipher.final(),
    ]);
    const state = JSON.parse(plaintext.toString("utf8"));
    if (
      state?.version !== 1 ||
      !Array.isArray(state.activities) ||
      state.activities.length > MAX_ACTIVITIES ||
      (state.tombstones !== undefined &&
        (!Array.isArray(state.tombstones) ||
          state.tombstones.length > MAX_TOMBSTONES))
    ) {
      throw new Error("Decrypted relay state is invalid");
    }
    return state;
  }

  save(state) {
    const plaintext = Buffer.from(JSON.stringify(state), "utf8");
    const iv = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", this.key, iv);
    cipher.setAAD(STATE_AAD);
    const ciphertext = Buffer.concat([
      cipher.update(plaintext),
      cipher.final(),
    ]);
    const envelope = Buffer.from(JSON.stringify({
      version: 1,
      algorithm: "aes-256-gcm",
      iv: iv.toString("base64"),
      tag: cipher.getAuthTag().toString("base64"),
      ciphertext: ciphertext.toString("base64"),
    }), "utf8");
    const temporaryPath = join(
      dirname(this.path),
      `.${basename(this.path)}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`,
    );
    try {
      writeFileSync(temporaryPath, envelope, {
        encoding: null,
        flag: "wx",
        mode: 0o600,
      });
      chmodSync(temporaryPath, 0o600);
      renameSync(temporaryPath, this.path);
      chmodSync(this.path, 0o600);
    } catch (error) {
      try {
        unlinkSync(temporaryPath);
      } catch {
        // The atomic rename may already have consumed the temporary file.
      }
      throw error;
    }
  }
}

function logRecord(stream, level, event, fields = {}) {
  const safeFields = {};
  for (const [key, value] of Object.entries(fields)) {
    if (value === undefined) continue;
    if (value instanceof Error) {
      safeFields[key] = value.message;
    } else if (
      typeof value === "string" ||
      typeof value === "number" ||
      typeof value === "boolean" ||
      value === null
    ) {
      safeFields[key] = value;
    }
  }
  stream.write(
    `${JSON.stringify({
      timestamp: new Date().toISOString(),
      level,
      event,
      ...safeFields,
    })}\n`,
  );
}

export function createLogger({
  output = process.stdout,
  errorOutput = process.stderr,
} = {}) {
  return {
    debug(event, fields) {
      logRecord(output, "debug", event, fields);
    },
    info(event, fields) {
      logRecord(output, "info", event, fields);
    },
    warn(event, fields) {
      logRecord(errorOutput, "warning", event, fields);
    },
    error(event, fields) {
      logRecord(errorOutput, "error", event, fields);
    },
  };
}

function sha256Hex(value) {
  return createHash("sha256").update(value).digest("hex");
}

export function tokenFingerprint(token) {
  return sha256Hex(token).slice(0, 12);
}

function safeTokenEquals(received, expected) {
  const receivedDigest = createHash("sha256").update(received).digest();
  const expectedDigest = createHash("sha256").update(expected).digest();
  return timingSafeEqual(receivedDigest, expectedDigest);
}

function clipUTF8(value, maximumBytes) {
  if (Buffer.byteLength(value, "utf8") <= maximumBytes) return value;
  const ellipsis = "…";
  const budget = Math.max(
    0,
    maximumBytes - Buffer.byteLength(ellipsis, "utf8"),
  );
  let result = "";
  let usedBytes = 0;
  for (const character of value) {
    const characterBytes = Buffer.byteLength(character, "utf8");
    if (usedBytes + characterBytes > budget) break;
    result += character;
    usedBytes += characterBytes;
  }
  return result + ellipsis;
}

function cleanText(value, field, maximumBytes, { allowEmpty = false } = {}) {
  if (typeof value !== "string") {
    throw new RelayError(400, `${field} must be a string`);
  }
  const cleaned = value
    .replace(/[\u0000-\u001f\u007f]/gu, " ")
    .replace(/\s+/gu, " ")
    .trim();
  if (!allowEmpty && !cleaned) {
    throw new RelayError(400, `${field} must not be empty`);
  }
  return clipUTF8(cleaned, maximumBytes);
}

function finiteNumber(value, field, minimum, maximum) {
  if (
    typeof value !== "number" ||
    !Number.isFinite(value) ||
    value < minimum ||
    value > maximum
  ) {
    throw new RelayError(
      400,
      `${field} must be a finite number between ${minimum} and ${maximum}`,
    );
  }
  return value;
}

function normalizeCue(rawCue, index, duration) {
  if (!rawCue || typeof rawCue !== "object" || Array.isArray(rawCue)) {
    throw new RelayError(400, `cues[${index}] must be an object`);
  }
  const startValue = rawCue.start ?? rawCue.startTime;
  const endValue = rawCue.end ?? rawCue.endTime;
  const textValue = rawCue.text ?? rawCue.line;
  const start = finiteNumber(
    startValue,
    `cues[${index}].start`,
    0,
    MAX_DURATION_SECONDS,
  );
  const end = finiteNumber(
    endValue,
    `cues[${index}].end`,
    0,
    MAX_DURATION_SECONDS,
  );
  if (end <= start) {
    throw new RelayError(
      400,
      `cues[${index}].end must be greater than start`,
    );
  }
  if (start >= duration) {
    throw new RelayError(
      400,
      `cues[${index}].start must be before the declared duration`,
    );
  }
  return {
    start,
    end: Math.min(end, duration),
    text: cleanText(textValue, `cues[${index}].text`, 1_024),
  };
}

export function validateActivityInput(rawInput, allowedBundleID = null) {
  if (
    !rawInput ||
    typeof rawInput !== "object" ||
    Array.isArray(rawInput)
  ) {
    throw new RelayError(400, "Request body must be a JSON object");
  }

  const pushToken = cleanText(rawInput.pushToken, "pushToken", 512);
  if (
    pushToken.length < 32 ||
    pushToken.length > 512 ||
    pushToken.length % 2 !== 0 ||
    !/^[0-9a-f]+$/iu.test(pushToken)
  ) {
    throw new RelayError(
      400,
      "pushToken must be an even-length hexadecimal ActivityKit token",
    );
  }

  const bundleID = cleanText(rawInput.bundleID, "bundleID", 255);
  if (
    !/^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$/u.test(
      bundleID,
    )
  ) {
    throw new RelayError(400, "bundleID is not a valid bundle identifier");
  }
  if (allowedBundleID && bundleID !== allowedBundleID) {
    throw new RelayError(
      403,
      "bundleID is not authorized by this relay",
      "topic_not_allowed",
    );
  }

  const clientSessionID = cleanText(
    rawInput.clientSessionID ?? "legacy",
    "clientSessionID",
    128,
  );
  if (!/^[A-Za-z0-9._:-]+$/u.test(clientSessionID)) {
    throw new RelayError(
      400,
      "clientSessionID contains unsupported characters",
    );
  }
  let anchorTimestampMS = null;
  if (rawInput.anchorTimestampMS !== undefined) {
    anchorTimestampMS = finiteNumber(
      rawInput.anchorTimestampMS,
      "anchorTimestampMS",
      0,
      8_640_000_000_000_000,
    );
  }

  const duration = finiteNumber(
    rawInput.duration,
    "duration",
    0,
    MAX_DURATION_SECONDS,
  );
  const position = finiteNumber(
    rawInput.position,
    "position",
    0,
    duration + 1,
  );
  if (typeof rawInput.isPlaying !== "boolean") {
    throw new RelayError(400, "isPlaying must be a boolean");
  }
  if (typeof rawInput.frequentPushesEnabled !== "boolean") {
    throw new RelayError(
      400,
      "frequentPushesEnabled must be a boolean",
    );
  }
  if (
    !Number.isSafeInteger(rawInput.generation) ||
    rawInput.generation < 0
  ) {
    throw new RelayError(
      400,
      "generation must be a non-negative safe integer",
    );
  }

  const playbackRate =
    rawInput.playbackRate === undefined
      ? 1
      : finiteNumber(rawInput.playbackRate, "playbackRate", 0.25, 4);

  if (!Array.isArray(rawInput.cues)) {
    throw new RelayError(400, "cues must be an array");
  }
  if (rawInput.cues.length > MAX_CUES) {
    throw new RelayError(400, `cues must contain at most ${MAX_CUES} items`);
  }
  const cues = rawInput.cues
    .map((cue, index) => normalizeCue(cue, index, duration))
    .sort((left, right) => left.start - right.start || left.end - right.end);

  return {
    pushToken: pushToken.toLowerCase(),
    bundleID,
    videoID: cleanText(rawInput.videoID, "videoID", 128),
    title: cleanText(rawInput.title, "title", 512, { allowEmpty: true }),
    source: cleanText(rawInput.source, "source", 64, { allowEmpty: true }),
    position: Math.min(position, duration),
    isPlaying: rawInput.isPlaying,
    duration,
    cues,
    generation: rawInput.generation,
    frequentPushesEnabled: rawInput.frequentPushesEnabled,
    playbackRate,
    clientSessionID,
    anchorTimestampMS,
  };
}

function contentStatePayload(state) {
  return {
    line: state.line,
    source: state.source,
    videoID: state.videoID,
    videoTitle: state.videoTitle,
    isPlaying: state.isPlaying,
    cueStartMS: state.cueStartMS,
    cueEndMS: state.cueEndMS,
    ...(state.nextLine
      ? {
          nextLine: state.nextLine,
          nextCueStartMS: state.nextCueStartMS,
          nextCueEndMS: state.nextCueEndMS,
        }
      : {}),
    revision: state.revision,
  };
}

export function buildLiveActivityPayload({
  event,
  state,
  timestamp,
  staleDate,
  dismissalDate,
}) {
  const boundedState = contentStatePayload(state);

  const makePayload = () => ({
    aps: {
      timestamp,
      event,
      "content-state": boundedState,
      ...(Number.isSafeInteger(staleDate) && staleDate > timestamp
        ? { "stale-date": staleDate }
        : {}),
      ...(Number.isSafeInteger(dismissalDate)
        ? { "dismissal-date": dismissalDate }
        : {}),
      "relevance-score": 1,
    },
  });

  let payload = makePayload();
  let encoded = Buffer.from(JSON.stringify(payload));
  for (let iteration = 0;
    encoded.length > MAX_APNS_PAYLOAD_BYTES && iteration < 24;
    iteration += 1) {
    const nextBytes = Buffer.byteLength(boundedState.nextLine ?? "", "utf8");
    const lineBytes = Buffer.byteLength(boundedState.line, "utf8");
    const titleBytes = Buffer.byteLength(boundedState.videoTitle, "utf8");
    if (nextBytes > 96) {
      boundedState.nextLine = clipUTF8(
        boundedState.nextLine,
        Math.max(96, Math.floor(nextBytes * 0.7)),
      );
    } else if (lineBytes > 128) {
      boundedState.line = clipUTF8(
        boundedState.line,
        Math.max(128, Math.floor(lineBytes * 0.7)),
      );
    } else if (titleBytes > 64) {
      boundedState.videoTitle = clipUTF8(
        boundedState.videoTitle,
        Math.max(64, Math.floor(titleBytes * 0.7)),
      );
    } else if (boundedState.nextLine) {
      delete boundedState.nextLine;
      delete boundedState.nextCueStartMS;
      delete boundedState.nextCueEndMS;
    } else {
      break;
    }
    payload = makePayload();
    encoded = Buffer.from(JSON.stringify(payload));
  }

  if (encoded.length > MAX_APNS_PAYLOAD_BYTES) {
    throw new RelayError(
      400,
      "Encoded Live Activity payload exceeds the APNs safety limit",
      "payload_too_large",
    );
  }
  return payload;
}

function base64URLJSON(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

export function createProviderJWT({
  teamID,
  keyID,
  privateKey,
  issuedAtSeconds,
}) {
  const header = base64URLJSON({ alg: "ES256", kid: keyID });
  const claims = base64URLJSON({ iss: teamID, iat: issuedAtSeconds });
  const signingInput = `${header}.${claims}`;
  const signature = cryptoSign(
    "sha256",
    Buffer.from(signingInput),
    {
      key: privateKey,
      dsaEncoding: "ieee-p1363",
    },
  );
  return `${signingInput}.${signature.toString("base64url")}`;
}

export function classifyAPNsResponse(status, reason = "") {
  const invalidTokenReasons = new Set([
    "BadDeviceToken",
    "DeviceTokenNotForTopic",
    "ExpiredToken",
    "Unregistered",
  ]);
  return {
    accepted: status === 200,
    invalidateToken: status === 410 || invalidTokenReasons.has(reason),
    retryable: status === 0 || status === 429 || status >= 500,
    providerTokenExpired: reason === "ExpiredProviderToken",
    permanent:
      status !== 200 &&
      status !== 0 &&
      status !== 429 &&
      status < 500 &&
      !invalidTokenReasons.has(reason) &&
      status !== 410,
  };
}

function APNsOrigin(environment) {
  return environment === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
}

export class APNsClient {
  constructor({
    teamID,
    keyID,
    privateKeyPath,
    environment,
    logger,
    now = () => Date.now(),
    connect = http2.connect,
  }) {
    this.teamID = teamID;
    this.keyID = keyID;
    this.environment = environment;
    this.logger = logger;
    this.now = now;
    this.connect = connect;
    this.origin = APNsOrigin(environment);
    this.privateKey = createPrivateKey(readFileSync(privateKeyPath));
    this.providerToken = "";
    this.providerTokenCreatedAt = 0;
    this.session = null;
  }

  providerAuthorization() {
    const nowMS = this.now();
    if (
      !this.providerToken ||
      nowMS - this.providerTokenCreatedAt >= PROVIDER_TOKEN_LIFETIME_MS
    ) {
      this.providerToken = createProviderJWT({
        teamID: this.teamID,
        keyID: this.keyID,
        privateKey: this.privateKey,
        issuedAtSeconds: Math.floor(nowMS / 1_000),
      });
      this.providerTokenCreatedAt = nowMS;
    }
    return `bearer ${this.providerToken}`;
  }

  invalidateProviderAuthorization() {
    this.providerToken = "";
    this.providerTokenCreatedAt = 0;
  }

  activeSession() {
    if (this.session && !this.session.closed && !this.session.destroyed) {
      return this.session;
    }
    const session = this.connect(this.origin);
    this.session = session;
    session.on("error", (error) => {
      this.logger.error("apns_connection_error", { error });
    });
    session.on("goaway", (errorCode) => {
      this.logger.warn("apns_connection_goaway", { errorCode });
      if (this.session === session) this.session = null;
      session.close();
    });
    session.on("close", () => {
      if (this.session === session) this.session = null;
    });
    return session;
  }

  async send({
    activityID,
    pushToken,
    bundleID,
    payload,
    priority = 10,
    expiration,
    collapseID,
  }) {
    const body = Buffer.from(JSON.stringify(payload));
    if (body.length > 4_096) {
      throw new RelayError(
        400,
        "APNs payload exceeds 4 KB",
        "payload_too_large",
      );
    }

    const headers = {
      ":method": "POST",
      ":path": `/3/device/${pushToken}`,
      authorization: this.providerAuthorization(),
      "content-type": "application/json",
      "apns-push-type": "liveactivity",
      "apns-topic": `${bundleID}.push-type.liveactivity`,
      "apns-priority": String(priority),
      "apns-expiration": String(Math.max(0, Math.floor(expiration))),
      "apns-collapse-id": collapseID.slice(0, 64),
    };

    let result;
    let refreshedExpiredProviderToken = false;
    while (true) {
      headers.authorization = this.providerAuthorization();
      try {
        result = await this.sendRequest(headers, body);
      } catch (error) {
        this.logger.error("apns_network_error", {
          activityID,
          token: tokenFingerprint(pushToken),
          error,
        });
        return {
          status: 0,
          reason: "NetworkError",
          ...classifyAPNsResponse(0, "NetworkError"),
        };
      }
      if (
        result.reason === "ExpiredProviderToken" &&
        !refreshedExpiredProviderToken
      ) {
        refreshedExpiredProviderToken = true;
        this.invalidateProviderAuthorization();
        this.logger.warn("apns_provider_token_refreshed", { activityID });
        continue;
      }
      break;
    }

    const classification = classifyAPNsResponse(
      result.status,
      result.reason,
    );
    const fields = {
      activityID,
      token: tokenFingerprint(pushToken),
      status: result.status,
      reason: result.reason || undefined,
      APNsID: result.APNsID || undefined,
    };
    if (classification.accepted) {
      this.logger.info("apns_accepted", fields);
    } else if (classification.invalidateToken) {
      this.logger.warn("apns_token_invalid", fields);
    } else if (result.status === 429) {
      this.logger.warn("apns_throttled", fields);
    } else if (result.status >= 500) {
      this.logger.error("apns_server_error", fields);
    } else {
      this.logger.error("apns_rejected", fields);
    }
    return { ...result, ...classification };
  }

  sendRequest(headers, body) {
    return new Promise((resolve, reject) => {
      const request = this.activeSession().request(headers);
      const chunks = [];
      let responseHeaders = {};
      let settled = false;
      const timeout = setTimeout(() => {
        if (settled) return;
        settled = true;
        request.close(http2.constants.NGHTTP2_CANCEL);
        reject(new Error("APNs request timed out"));
      }, APNS_REQUEST_TIMEOUT_MS);

      const finish = (callback) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        callback();
      };
      request.on("response", (headersValue) => {
        responseHeaders = headersValue;
      });
      request.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
      request.on("error", (error) => finish(() => reject(error)));
      request.on("end", () => finish(() => {
        const status = Number(responseHeaders[":status"] ?? 0);
        let reason = "";
        if (chunks.length > 0) {
          try {
            reason =
              JSON.parse(Buffer.concat(chunks).toString("utf8")).reason ?? "";
          } catch {
            reason = "InvalidAPNsResponse";
          }
        }
        resolve({
          status,
          reason,
          APNsID: responseHeaders["apns-id"] ?? "",
        });
      }));
      request.end(body);
    });
  }

  close() {
    this.session?.close();
    this.session = null;
  }
}

function cueIndexAtPosition(cues, position) {
  let candidate = -1;
  for (let index = 0; index < cues.length; index += 1) {
    if (cues[index].start > position) break;
    if (position < cues[index].end) candidate = index;
  }
  return candidate;
}

function nextCueIndexAtPosition(cues, position) {
  return cues.findIndex((cue) => cue.start > position + 0.001);
}

function milliseconds(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return 0;
  return Math.min(Number.MAX_SAFE_INTEGER, Math.round(seconds * 1_000));
}

export class ActivityScheduler {
  constructor({
    APNsClient: APNsClientValue,
    logger,
    allowedBundleID = null,
    stateStore = null,
    now = () => Date.now(),
    setTimer = setTimeout,
    clearTimer = clearTimeout,
    maxActivities = MAX_ACTIVITIES,
    minimumUpdateIntervalMS = MIN_ACTIVITY_UPDATE_INTERVAL_MS,
  }) {
    this.APNsClient = APNsClientValue;
    this.logger = logger;
    this.allowedBundleID = allowedBundleID;
    this.stateStore = stateStore;
    this.now = now;
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    this.maxActivities = maxActivities;
    this.minimumUpdateIntervalMS = minimumUpdateIntervalMS;
    this.activities = new Map();
    this.tombstones = new Map();
    this.isRestoring = false;
  }

  async restoreFromStore() {
    if (!this.stateStore) return { restored: 0, discarded: 0 };
    const state = this.stateStore.load();
    const nowMS = this.now();
    for (const saved of state.tombstones ?? []) {
      if (
        typeof saved?.activityID !== "string" ||
        !validActivityID(saved.activityID) ||
        !Number.isFinite(saved.expiresAtMS) ||
        saved.expiresAtMS <= nowMS
      ) {
        continue;
      }
      this.tombstones.set(saved.activityID, {
        activityID: saved.activityID,
        clientSessionID:
          typeof saved.clientSessionID === "string"
            ? saved.clientSessionID
            : null,
        generation: Number.isSafeInteger(saved.generation)
          ? saved.generation
          : null,
        expiresAtMS: saved.expiresAtMS,
      });
    }
    this.pruneTombstones();
    this.isRestoring = true;
    let restored = 0;
    let discarded = 0;
    try {
      for (const saved of state.activities) {
        const activityID = saved?.activityID;
        if (typeof activityID !== "string" || !validActivityID(activityID)) {
          discarded += 1;
          this.logger.warn("state_activity_discarded", {
            reason: "invalid_activity_id",
          });
          continue;
        }
        try {
          const result = await this.upsertActivity(activityID, saved, {
            restoring: true,
            restoreMetadata: saved,
          });
          if (result.deliveryStatus === "rejected") discarded += 1;
          else restored += 1;
          if (saved.ending && this.activities.has(activityID)) {
            await this.endActivity(activityID);
          }
        } catch (error) {
          discarded += 1;
          this.logger.warn("state_activity_discarded", {
            activityID,
            error,
          });
        }
      }
    } finally {
      this.isRestoring = false;
    }
    this.persistState({ strict: true });
    if (restored > 0 || discarded > 0) {
      this.logger.info("state_restore_completed", { restored, discarded });
    }
    return { restored, discarded };
  }

  async upsertActivity(
    activityID,
    rawInput,
    { restoring = false, restoreMetadata = null } = {},
  ) {
    const input = validateActivityInput(
      rawInput,
      this.allowedBundleID,
    );
    this.pruneTombstones();
    if (this.tombstones.has(activityID) && !restoring) {
      throw new RelayError(
        409,
        "activity has already ended",
        "activity_ended",
      );
    }
    const existing = this.activities.get(activityID);
    const nowMS = this.now();
    const sessionChanged =
      Boolean(existing) &&
      input.clientSessionID !== existing.clientSessionID;
    if (
      existing &&
      sessionChanged &&
      existing.retiredClientSessionIDs.includes(input.clientSessionID)
    ) {
      throw new RelayError(
        409,
        "clientSessionID belongs to a superseded client process",
        "stale_client_session",
      );
    }
    if (
      existing &&
      !sessionChanged &&
      input.generation < existing.generation
    ) {
      throw new RelayError(
        409,
        "generation is older than the active schedule",
        "stale_generation",
      );
    }
    if (existing) {
      const tokenChanged = input.pushToken !== existing.pushToken;
      const elapsedSinceUpdate = nowMS - existing.lastRequestWallMS;
      if (
        !restoring &&
        !sessionChanged &&
        !tokenChanged &&
        elapsedSinceUpdate >= 0 &&
        elapsedSinceUpdate < this.minimumUpdateIntervalMS
      ) {
        const retryAfterMS =
          this.minimumUpdateIntervalMS - elapsedSinceUpdate;
        throw new RelayError(
          429,
          "Activity snapshots are arriving too quickly",
          "activity_rate_limited",
          { retryAfterMS },
        );
      }
    } else if (this.activities.size >= this.maxActivities) {
      throw new RelayError(
        429,
        `Relay capacity is limited to ${this.maxActivities} activities`,
        "activity_capacity_reached",
        { retryAfterMS: 1_000 },
      );
    }

    const sourceAnchorMS = input.anchorTimestampMS ?? nowMS;
    const rawTransitMS = nowMS - sourceAnchorMS;
    if (
      !restoring &&
      input.isPlaying &&
      rawTransitMS > MAX_CLIENT_TRANSIT_COMPENSATION_MS
    ) {
      throw new RelayError(
        409,
        "snapshot anchor is too old to replace the active schedule",
        "stale_anchor",
      );
    }
    if (existing) this.cancelRecordTimers(existing);
    const transitMS =
      input.isPlaying &&
      rawTransitMS >= 0 &&
      (restoring || rawTransitMS <= MAX_CLIENT_TRANSIT_COMPENSATION_MS)
        ? rawTransitMS
        : 0;
    const transitSeconds = transitMS / 1_000;
    const projectedInputPosition =
      input.position + transitSeconds * input.playbackRate;
    const position = input.duration > 0
      ? Math.min(input.duration, projectedInputPosition)
      : 0;
    const retiredClientSessionIDs = [
      ...(existing?.retiredClientSessionIDs ?? []),
    ];
    if (
      sessionChanged &&
      !retiredClientSessionIDs.includes(existing.clientSessionID)
    ) {
      retiredClientSessionIDs.push(existing.clientSessionID);
      if (retiredClientSessionIDs.length > 8) {
        retiredClientSessionIDs.splice(
          0,
          retiredClientSessionIDs.length - 8,
        );
      }
    }
    const record = {
      ...input,
      activityID,
      position,
      anchorTimestampMS: nowMS,
      anchorWallMS: nowMS,
      version: (existing?.version ?? 0) + 1,
      revision:
        Number.isSafeInteger(restoreMetadata?.revision) &&
        restoreMetadata.revision >= 0
          ? restoreMetadata.revision
          : existing?.revision ?? 0,
      lastTimestamp:
        Number.isSafeInteger(restoreMetadata?.lastTimestamp) &&
        restoreMetadata.lastTimestamp >= 0
          ? restoreMetadata.lastTimestamp
          : existing?.lastTimestamp ?? 0,
      deliveryTail: existing?.deliveryTail ?? Promise.resolve(),
      eventTimer: null,
      retryTimers: new Set(),
      invalidToken: false,
      ending: false,
      lastState:
        restoreMetadata?.lastState &&
        typeof restoreMetadata.lastState === "object"
          ? restoreMetadata.lastState
          : existing?.lastState ?? null,
      lastRequestWallMS: nowMS,
      retiredClientSessionIDs:
        Array.isArray(restoreMetadata?.retiredClientSessionIDs)
          ? restoreMetadata.retiredClientSessionIDs
            .filter(
              (value) =>
                typeof value === "string" &&
                /^[A-Za-z0-9._:-]{1,128}$/u.test(value),
            )
            .slice(-8)
          : retiredClientSessionIDs,
      safetyExpiresAtMS:
        Number.isFinite(restoreMetadata?.safetyExpiresAtMS) &&
        restoreMetadata.safetyExpiresAtMS >= 0
          ? restoreMetadata.safetyExpiresAtMS
          : nowMS + ACTIVITY_SAFETY_EXPIRY_MS,
    };
    this.activities.set(activityID, record);
    try {
      this.persistState({ strict: true });
    } catch (error) {
      this.activities.delete(activityID);
      if (existing) {
        this.activities.set(activityID, existing);
        this.scheduleNextEvent(existing);
      }
      throw error;
    }

    const tokenChanged =
      Boolean(existing) && existing.pushToken !== record.pushToken;
    this.logger.info("activity_registered", {
      activityID,
      generation: record.generation,
      token: tokenFingerprint(record.pushToken),
      tokenChanged,
      isPlaying: record.isPlaying,
      cueCount: record.cues.length,
      frequentPushesEnabled: record.frequentPushesEnabled,
      clientSessionChanged: sessionChanged,
      restored: restoring,
    });

    const scheduledCueCount = record.isPlaying
      ? record.cues.filter(
        (cue) => cue.start > record.position + EVENT_EPSILON_SECONDS,
      ).length
      : 0;
    const delivery = await this.enqueueUpdate(
      record,
      this.stateForPosition(record),
    );
    if (
      this.activities.get(activityID) === record &&
      delivery.deliveryStatus !== "rejected"
    ) {
      this.scheduleNextEvent(record);
    }
    return {
      activityID,
      generation: record.generation,
      scheduledCueCount,
      isPlaying: record.isPlaying,
      tokenFingerprint: tokenFingerprint(record.pushToken),
      ...delivery,
    };
  }

  scheduleNextEvent(record) {
    if (!this.isCurrent(record, record.version) || record.ending) return;
    if (record.eventTimer !== null) {
      this.clearTimer(record.eventTimer);
      record.eventTimer = null;
    }
    const version = record.version;
    const nowMS = this.now();
    if (nowMS >= record.safetyExpiresAtMS) {
      this.setEventTimer(record, nowMS, "safety", version);
      return;
    }
    if (!record.isPlaying || record.duration <= 0) {
      this.setEventTimer(
        record,
        record.safetyExpiresAtMS,
        "safety",
        version,
      );
      return;
    }

    const position = this.projectedPosition(record);
    if (position >= record.duration - EVENT_EPSILON_SECONDS) {
      this.setEventTimer(record, nowMS, "natural_end", version);
      return;
    }
    const currentIndex = cueIndexAtPosition(record.cues, position);
    const nextIndex = nextCueIndexAtPosition(record.cues, position);
    const currentCue =
      currentIndex >= 0 ? record.cues[currentIndex] : null;
    const nextCue = nextIndex >= 0 ? record.cues[nextIndex] : null;
    let nextPosition = record.duration;
    let eventKind = "natural_end";
    if (nextCue) {
      nextPosition = nextCue.start;
      eventKind = "caption";
    }
    if (currentCue) {
      const followingStart = nextCue?.start ?? record.duration;
      const gapDuration = followingStart - currentCue.end;
      if (
        gapDuration >= GAP_STATE_THRESHOLD_SECONDS &&
        currentCue.end > position + EVENT_EPSILON_SECONDS &&
        currentCue.end < nextPosition
      ) {
        nextPosition = currentCue.end;
        eventKind = "gap";
      }
    }
    const eventDueMS =
      record.anchorWallMS +
      ((nextPosition - record.position) / record.playbackRate) * 1_000;
    if (record.safetyExpiresAtMS <= eventDueMS) {
      this.setEventTimer(
        record,
        record.safetyExpiresAtMS,
        "safety",
        version,
      );
    } else {
      this.setEventTimer(record, eventDueMS, eventKind, version);
    }
  }

  setEventTimer(record, dueMS, eventKind, version) {
    const delay = Math.max(0, dueMS - this.now());
    record.eventTimer = this.setTimer(async () => {
      record.eventTimer = null;
      try {
        if (!this.isCurrent(record, version) || record.ending) return;
        if (
          eventKind === "safety" ||
          this.now() >= record.safetyExpiresAtMS
        ) {
          await this.endActivity(record.activityID, {
            expectedRecord: record,
            establishTombstone: true,
          });
          return;
        }
        const position = this.projectedPosition(record);
        if (eventKind === "natural_end_commit") {
          await this.endActivity(record.activityID, {
            natural: true,
            expectedRecord: record,
            establishTombstone: true,
          });
          return;
        }
        if (
          eventKind === "natural_end" ||
          position >= record.duration - EVENT_EPSILON_SECONDS
        ) {
          // Give autoplay/navigation a short opportunity to replace this
          // timeline while the same Activity is still valid. A newer PUT
          // cancels this versioned timer. Once the grace period commits the
          // end, a tombstone fences any older request still in flight.
          this.setEventTimer(
            record,
            Math.min(
              this.now() + NATURAL_END_GRACE_MS,
              record.safetyExpiresAtMS,
            ),
            "natural_end_commit",
            version,
          );
          return;
        }
        const delivery = await this.enqueueUpdate(
          record,
          this.stateForPosition({ ...record, position }),
          { immediate: false },
        );
        if (
          this.isCurrent(record, version) &&
          delivery.deliveryStatus !== "rejected"
        ) {
          this.scheduleNextEvent(record);
        }
      } catch (error) {
        this.logger.error("scheduled_operation_failed", {
          activityID: record.activityID,
          generation: record.generation,
          error,
        });
      }
    }, delay);
  }

  stateForPosition(record) {
    const currentIndex = cueIndexAtPosition(record.cues, record.position);
    if (currentIndex >= 0) return this.stateForCue(record, currentIndex);
    const nextIndex = nextCueIndexAtPosition(record.cues, record.position);
    const nextCue = nextIndex >= 0 ? record.cues[nextIndex] : null;
    return {
      line: "♪",
      source: "",
      videoID: record.videoID,
      videoTitle: record.title || "YouTube",
      isPlaying: record.isPlaying,
      cueStartMS: 0,
      cueEndMS: 0,
      nextLine: nextCue?.text,
      nextCueStartMS: nextCue ? milliseconds(nextCue.start) : undefined,
      nextCueEndMS: nextCue ? milliseconds(nextCue.end) : undefined,
      staleDate: record.isPlaying && nextCue
        ? this.wallClockSecondsForPosition(record, nextCue.start)
        : undefined,
      expiration: nextCue
        ? this.wallClockSecondsForPosition(record, nextCue.end)
        : Math.floor(this.now() / 1_000) + 60,
    };
  }

  stateForCue(record, index) {
    const cue = record.cues[index];
    const nextCue = record.cues[index + 1] ?? null;
    return {
      line: cue.text,
      source: record.source,
      videoID: record.videoID,
      videoTitle: record.title || "YouTube",
      isPlaying: record.isPlaying,
      cueStartMS: milliseconds(cue.start),
      cueEndMS: milliseconds(cue.end),
      nextLine: nextCue?.text,
      nextCueStartMS: nextCue ? milliseconds(nextCue.start) : undefined,
      nextCueEndMS: nextCue ? milliseconds(nextCue.end) : undefined,
      staleDate: record.isPlaying && nextCue
        ? this.wallClockSecondsForPosition(record, nextCue.start)
        : undefined,
      expiration: this.wallClockSecondsForPosition(record, cue.end),
    };
  }

  wallClockSecondsForPosition(record, mediaPosition) {
    const wallMS =
      record.anchorWallMS +
      ((mediaPosition - record.position) / record.playbackRate) * 1_000;
    return Math.max(0, Math.floor(wallMS / 1_000));
  }

  projectedPosition(record) {
    if (!record.isPlaying) return record.position;
    const elapsed =
      ((this.now() - record.anchorWallMS) / 1_000) * record.playbackRate;
    return Math.min(record.duration, Math.max(0, record.position + elapsed));
  }

  nextTimestamp(record) {
    const timestamp = Math.max(
      Math.floor(this.now() / 1_000),
      record.lastTimestamp + 1,
    );
    record.lastTimestamp = timestamp;
    return timestamp;
  }

  enqueueUpdate(record, state, { immediate = true } = {}) {
    const version = record.version;
    record.deliveryTail = record.deliveryTail
      .catch(() => undefined)
      .then(async () => {
        if (!this.isCurrent(record, version) || record.ending) {
          return { deliveryStatus: "superseded" };
        }
        record.revision += 1;
        const timestamp = this.nextTimestamp(record);
        const contentState = {
          ...state,
          revision: record.revision,
        };
        delete contentState.staleDate;
        delete contentState.expiration;
        record.lastState = contentState;
        // Persist monotonic timestamp/revision before APNs sees them. After a
        // crash, replaying a newer unsent state is safe; replaying an
        // already-delivered timestamp may be ignored by ActivityKit.
        this.persistState({ strict: false });
        const payload = buildLiveActivityPayload({
          event: "update",
          state: contentState,
          timestamp,
          staleDate: state.staleDate,
        });
        const request = {
          activityID: record.activityID,
          pushToken: record.pushToken,
          bundleID: record.bundleID,
          payload,
          // Cue boundaries are predictable timeline updates. Priority 5 lets
          // APNs deliver them without consuming the limited high-priority
          // budget; registration, seek, pause/resume, and end remain 10.
          priority: immediate ? 10 : 5,
          expiration: Math.max(
            timestamp + 1,
            state.expiration ?? timestamp + 60,
          ),
          collapseID: `ci-${sha256Hex(record.activityID).slice(0, 32)}`,
        };
        return this.sendWithRetry(
          record,
          version,
          record.revision,
          request,
          0,
        );
      });
    return record.deliveryTail;
  }

  async sendWithRetry(
    record,
    version,
    revision,
    request,
    attempt,
    onTerminal = null,
  ) {
    if (
      !this.isCurrent(record, version) ||
      record.revision !== revision ||
      record.invalidToken
    ) {
      onTerminal?.();
      return { deliveryStatus: "superseded" };
    }
    const result = await this.APNsClient.send(request);
    if (result.invalidateToken) {
      record.invalidToken = true;
      this.removeRecord(record);
      this.logger.warn("activity_token_removed", {
        activityID: record.activityID,
        generation: record.generation,
        status: result.status,
        reason: result.reason,
      });
      onTerminal?.();
      return {
        deliveryStatus: "rejected",
        apnsStatus: result.status,
        apnsReason: result.reason || "InvalidActivityToken",
      };
    }
    if (result.permanent) {
      this.removeRecord(record);
      this.logger.error("activity_delivery_permanently_rejected", {
        activityID: record.activityID,
        generation: record.generation,
        status: result.status,
        reason: result.reason,
      });
      onTerminal?.();
      return {
        deliveryStatus: "rejected",
        apnsStatus: result.status,
        apnsReason: result.reason || "PermanentAPNsRejection",
      };
    }
    if (result.accepted) {
      onTerminal?.();
      return {
        deliveryStatus: "accepted",
        apnsStatus: result.status,
      };
    }
    if (!result.retryable || attempt >= RETRY_DELAYS_MS.length) {
      onTerminal?.();
      return {
        deliveryStatus: "rejected",
        apnsStatus: result.status,
        apnsReason: result.reason || "APNsDeliveryFailed",
      };
    }

    const delay = RETRY_DELAYS_MS[attempt];
    if (this.now() + delay >= request.expiration * 1_000) {
      this.logger.warn("apns_retry_expired", {
        activityID: record.activityID,
        generation: record.generation,
        status: result.status,
      });
      onTerminal?.();
      return {
        deliveryStatus: "rejected",
        apnsStatus: result.status,
        apnsReason: "RetryWindowExpired",
      };
    }
    let retryTimer;
    retryTimer = this.setTimer(async () => {
      record.retryTimers.delete(retryTimer);
      if (
        !this.isCurrent(record, version) ||
        record.revision !== revision
      ) {
        return;
      }
      await this.sendWithRetry(
        record,
        version,
        revision,
        request,
        attempt + 1,
        onTerminal,
      );
    }, delay);
    record.retryTimers.add(retryTimer);
    return {
      deliveryStatus: "retrying",
      apnsStatus: result.status,
      apnsReason: result.reason || "TemporaryAPNsFailure",
      retryAfterMS: delay,
    };
  }

  async endActivity(
    activityID,
    {
      natural = false,
      expectedRecord = null,
      establishTombstone = false,
    } = {},
  ) {
    const record = this.activities.get(activityID);
    if (!record) {
      if (establishTombstone) {
        this.recordTombstone(activityID, null);
        this.persistState({ strict: false });
      }
      return {
        activityID,
        ended: false,
        deliveryStatus: "not_found",
      };
    }
    if (expectedRecord && record !== expectedRecord) {
      return {
        activityID,
        ended: false,
        deliveryStatus: "superseded",
      };
    }

    if (establishTombstone) {
      this.recordTombstone(activityID, record);
    }
    this.cancelRecordTimers(record);
    record.version += 1;
    record.ending = true;
    const version = record.version;
    const position = this.projectedPosition(record);
    const currentIndex = cueIndexAtPosition(record.cues, position);
    const fallbackState = currentIndex >= 0
      ? this.stateForCue(record, currentIndex)
      : this.stateForPosition({ ...record, position, isPlaying: false });
    record.revision += 1;
    const timestamp = this.nextTimestamp(record);
    const state = {
      ...(record.lastState ?? fallbackState),
      isPlaying: false,
      nextLine: undefined,
      nextCueStartMS: undefined,
      nextCueEndMS: undefined,
      revision: record.revision,
    };
    delete state.staleDate;
    delete state.expiration;
    record.lastState = state;
    this.persistState({ strict: false });

    const payload = buildLiveActivityPayload({
      event: "end",
      state,
      timestamp,
      dismissalDate: timestamp - 1,
    });
    const request = {
      activityID: record.activityID,
      pushToken: record.pushToken,
      bundleID: record.bundleID,
      payload,
      priority: 10,
      expiration: timestamp + 60,
      collapseID: `ci-${sha256Hex(record.activityID).slice(0, 32)}`,
    };

    record.deliveryTail = record.deliveryTail
      .catch(() => undefined)
      .then(async () => {
        if (
          this.activities.get(activityID) !== record ||
          record.version !== version ||
          record.invalidToken
        ) {
          return { deliveryStatus: "superseded" };
        }
        return this.sendWithRetry(
          record,
          version,
          record.revision,
          request,
          0,
          () => {
            if (this.activities.get(activityID) !== record) return;
            this.removeRecord(record);
            this.logger.info("activity_ended", {
              activityID,
              generation: record.generation,
              natural,
            });
          },
        );
      });
    const delivery = await record.deliveryTail;
    return {
      activityID,
      ended: delivery.deliveryStatus === "accepted",
      ...delivery,
    };
  }

  isCurrent(record, version) {
    return (
      this.activities.get(record.activityID) === record &&
      record.version === version &&
      !record.invalidToken
    );
  }

  cancelRecordTimers(record) {
    if (record.eventTimer !== null) {
      this.clearTimer(record.eventTimer);
      record.eventTimer = null;
    }
    for (const timer of record.retryTimers) this.clearTimer(timer);
    record.retryTimers.clear();
  }

  removeRecord(record) {
    this.cancelRecordTimers(record);
    if (this.activities.get(record.activityID) === record) {
      this.activities.delete(record.activityID);
      this.persistState({ strict: false });
    }
  }

  pruneTombstones() {
    const nowMS = this.now();
    for (const [activityID, tombstone] of this.tombstones) {
      if (tombstone.expiresAtMS <= nowMS) {
        this.tombstones.delete(activityID);
      }
    }
    while (this.tombstones.size > MAX_TOMBSTONES) {
      const oldestActivityID = this.tombstones.keys().next().value;
      if (oldestActivityID === undefined) break;
      this.tombstones.delete(oldestActivityID);
    }
  }

  recordTombstone(activityID, record) {
    this.pruneTombstones();
    this.tombstones.delete(activityID);
    this.tombstones.set(activityID, {
      activityID,
      clientSessionID: record?.clientSessionID ?? null,
      generation:
        Number.isSafeInteger(record?.generation)
          ? record.generation
          : null,
      expiresAtMS: this.now() + ACTIVITY_TOMBSTONE_TTL_MS,
    });
    this.pruneTombstones();
  }

  persistentActivity(record) {
    const nowMS = this.now();
    return {
      activityID: record.activityID,
      pushToken: record.pushToken,
      bundleID: record.bundleID,
      videoID: record.videoID,
      title: record.title,
      source: record.source,
      position: this.projectedPosition(record),
      isPlaying: record.isPlaying,
      playbackRate: record.playbackRate,
      duration: record.duration,
      generation: record.generation,
      frequentPushesEnabled: record.frequentPushesEnabled,
      cues: record.cues,
      clientSessionID: record.clientSessionID,
      anchorTimestampMS: nowMS,
      revision: record.revision,
      lastTimestamp: record.lastTimestamp,
      lastState: record.lastState,
      retiredClientSessionIDs: record.retiredClientSessionIDs,
      safetyExpiresAtMS: record.safetyExpiresAtMS,
      ending: record.ending,
    };
  }

  persistState({ strict = false } = {}) {
    if (!this.stateStore || this.isRestoring) return true;
    try {
      this.pruneTombstones();
      this.stateStore.save({
        version: 1,
        activities: [...this.activities.values()].map(
          (record) => this.persistentActivity(record),
        ),
        tombstones: [...this.tombstones.values()],
      });
      return true;
    } catch (error) {
      this.logger.error("state_persistence_failed", { error });
      if (strict) {
        throw new RelayError(
          503,
          "The encrypted relay state could not be saved",
          "state_persistence_failed",
        );
      }
      return false;
    }
  }

  shutdown() {
    for (const record of this.activities.values()) {
      this.cancelRecordTimers(record);
    }
    this.persistState({ strict: false });
    this.APNsClient.close?.();
  }
}

function validActivityID(value) {
  return (
    value.length >= 1 &&
    value.length <= 128 &&
    /^[A-Za-z0-9._:-]+$/u.test(value)
  );
}

function sendJSON(response, statusCode, body, extraHeaders = {}) {
  const encoded = Buffer.from(JSON.stringify(body));
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": encoded.length,
    "cache-control": "no-store",
    ...extraHeaders,
  });
  response.end(encoded);
}

async function readJSONBody(request) {
  const chunks = [];
  let totalBytes = 0;
  for await (const chunk of request) {
    totalBytes += chunk.length;
    if (totalBytes > MAX_REQUEST_BYTES) {
      throw new RelayError(413, "Request body exceeds 1 MiB", "body_too_large");
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) {
    throw new RelayError(400, "Request body is required");
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new RelayError(400, "Request body is not valid JSON");
  }
}

function authorized(request, accessToken) {
  const header = request.headers.authorization;
  if (typeof header !== "string" || !header.startsWith("Bearer ")) {
    return false;
  }
  return safeTokenEquals(header.slice("Bearer ".length), accessToken);
}

export function createRelayHTTPRequestHandler({
  scheduler,
  accessToken,
  logger,
}) {
  return async (request, response) => {
    response.setHeader("x-content-type-options", "nosniff");
    const requestURL = new URL(request.url ?? "/", "http://localhost");
    if (request.method === "GET" && requestURL.pathname === "/healthz") {
      sendJSON(response, 200, { status: "ok" });
      return;
    }

    const match = requestURL.pathname.match(/^\/v1\/activities\/([^/]+)$/u);
    if (!match) {
      sendJSON(response, 404, { error: "not_found" });
      return;
    }
    if (!["PUT", "DELETE"].includes(request.method ?? "")) {
      response.setHeader("allow", "PUT, DELETE");
      sendJSON(response, 405, { error: "method_not_allowed" });
      return;
    }
    if (!authorized(request, accessToken)) {
      logger.warn("relay_unauthorized", {
        method: request.method,
      });
      response.setHeader("www-authenticate", "Bearer");
      sendJSON(response, 401, { error: "unauthorized" });
      return;
    }

    let activityID;
    try {
      activityID = decodeURIComponent(match[1]);
    } catch {
      sendJSON(response, 400, { error: "invalid_activity_id" });
      return;
    }
    if (!validActivityID(activityID)) {
      sendJSON(response, 400, { error: "invalid_activity_id" });
      return;
    }

    try {
      if (request.method === "PUT") {
        const input = await readJSONBody(request);
        const result = await scheduler.upsertActivity(activityID, input);
        sendJSON(
          response,
          result.deliveryStatus === "rejected" ? 424 : 202,
          result,
        );
      } else {
        const result = await scheduler.endActivity(activityID, {
          establishTombstone: true,
        });
        const statusCode =
          result.deliveryStatus === "rejected"
            ? 424
            : result.deliveryStatus === "not_found"
              ? 200
              : 202;
        sendJSON(response, statusCode, result);
      }
    } catch (error) {
      const statusCode =
        error instanceof RelayError ? error.statusCode : 500;
      const code =
        error instanceof RelayError ? error.code : "internal_error";
      if (statusCode >= 500) {
        logger.error("relay_request_failed", {
          activityID,
          method: request.method,
          error,
        });
      }
      const retryAfterMS =
        error instanceof RelayError ? error.retryAfterMS : undefined;
      sendJSON(
        response,
        statusCode,
        {
          error: code,
          message:
            error instanceof RelayError
              ? error.message
              : "Internal server error",
          ...(retryAfterMS ? { retryAfterMS } : {}),
        },
        retryAfterMS
          ? { "retry-after": String(Math.max(1, Math.ceil(retryAfterMS / 1_000))) }
          : {},
      );
    }
  };
}

export function createRelayHTTPServer(options) {
  return http.createServer(createRelayHTTPRequestHandler(options));
}

export async function startRelay(environment = process.env) {
  const config = loadConfig(environment);
  const logger = createLogger();
  const stateStore = config.statePath
    ? new EncryptedStateStore({
      path: config.statePath,
      key: config.stateKey,
    })
    : null;
  if (config.APNsEnvironment === "production" && !stateStore) {
    logger.warn("production_state_store_disabled", {
      message:
        "Configure RELAY_STATE_PATH and RELAY_STATE_KEY to survive restarts",
    });
  }
  const APNsClientValue = new APNsClient({
    teamID: config.teamID,
    keyID: config.keyID,
    privateKeyPath: config.privateKeyPath,
    environment: config.APNsEnvironment,
    logger,
  });
  const scheduler = new ActivityScheduler({
    APNsClient: APNsClientValue,
    logger,
    allowedBundleID: config.bundleID,
    stateStore,
  });
  await scheduler.restoreFromStore();
  const server = createRelayHTTPServer({
    scheduler,
    accessToken: config.accessToken,
    logger,
  });

  server.listen(config.port, "127.0.0.1", () => {
    logger.info("relay_listening", {
      port: config.port,
      APNsEnvironment: config.APNsEnvironment,
      bundleID: config.bundleID,
    });
  });

  const shutdown = (signal) => {
    logger.info("relay_shutdown", { signal });
    server.close(() => {
      scheduler.shutdown();
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 10_000).unref();
  };
  process.once("SIGINT", () => shutdown("SIGINT"));
  process.once("SIGTERM", () => shutdown("SIGTERM"));
  return { server, scheduler, APNsClient: APNsClientValue };
}

const isMain =
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  try {
    await startRelay();
  } catch (error) {
    createLogger().error("relay_start_failed", { error });
    process.exitCode = 1;
  }
}
