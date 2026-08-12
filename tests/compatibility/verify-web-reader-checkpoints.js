#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');

function fail(message) {
  throw new Error(message);
}

function usage(message) {
  if (message) console.error(`verify-web-reader-checkpoints: ${message}`);
  console.error('Usage: node verify-web-reader-checkpoints.js --runtime PATH --checkpoints PATH');
  process.exit(2);
}

function progressPercentageAtServerPrecision(value) {
  // Pinned Grimmory v3.3.1 persists this through MariaDB FLOAT and a Java
  // Float/JDBC round trip. The live server returns six significant digits.
  return Number(Number(value).toPrecision(6));
}

const postedSessionFields = [
  'bookId', 'bookType', 'startTime', 'endTime', 'durationSeconds',
  'durationFormatted', 'startProgress', 'endProgress', 'progressDelta',
  'startLocation', 'endLocation'
];
const listedSessionFields = [
  'id', 'bookId', 'bookTitle', 'bookType', 'startTime', 'endTime',
  'durationSeconds', 'startProgress', 'endProgress', 'progressDelta',
  'startLocation', 'endLocation', 'createdAt'
];

function hasExactKeys(value, fields) {
  return !!value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...fields].sort());
}

function roundedReadingSessionProgress(value) {
  return Math.round(Number(value) * 100) / 100;
}

function formattedReadingSessionDuration(seconds) {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const remainder = seconds % 60;
  if (hours > 0) return `${hours}h ${minutes}m ${remainder}s`;
  if (minutes > 0) return `${minutes}m ${remainder}s`;
  return `${remainder}s`;
}

function persistedReadingSessionTimestamp(value) {
  const match = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.\d{3}Z$/.exec(value || '');
  return match ? `${match[1]}Z` : null;
}

function parseServerLocalDateTime(value) {
  if (typeof value !== 'string' || !value) return NaN;
  return Date.parse(/(?:Z|[+-]\d{2}:\d{2})$/i.test(value) ? value : `${value}Z`);
}

function progressWasExactlyPersisted(posted, persisted) {
  return !!posted && !!persisted && /^epubcfi\(/.test(posted.cfi || '') &&
    posted.cfi === persisted.cfi &&
    (posted.href ?? null) === (persisted.href ?? null) &&
    Number.isFinite(Number(posted.percentage)) &&
    Number(persisted.percentage) === progressPercentageAtServerPrecision(posted.percentage);
}

function goProofIsExact(proof, progress) {
  const finiteFields = [
    'requestedPercentage', 'targetFraction', 'resolvedSection', 'visibleSection',
    'resolvedAnchor', 'textPages', 'contentPage', 'expectedPage', 'sectionStart',
    'sectionEnd', 'sectionWeight', 'pageStart', 'pageEnd', 'anchorStart',
    'anchorEnd', 'lastFraction',
    'postedPercentage', 'visibleRoundedPercentage'
  ];
  const integerFields = [
    'resolvedSection', 'visibleSection', 'textPages', 'contentPage',
    'expectedPage', 'visibleRoundedPercentage'
  ];
  return !!proof && finiteFields.every(field => Number.isFinite(proof[field])) &&
    integerFields.every(field => Number.isInteger(proof[field])) &&
    proof.resolvedSection >= 0 && proof.visibleSection >= 0 &&
    proof.textPages > 0 && proof.contentPage >= 0 && proof.contentPage < proof.textPages &&
    proof.expectedPage >= 0 && proof.expectedPage < proof.textPages &&
    proof.resolvedAnchor >= 0 && proof.resolvedAnchor <= 1 &&
    proof.requestedPercentage >= 0 && proof.requestedPercentage <= 100 &&
    proof.targetFraction >= 0 && proof.targetFraction <= 1 &&
    proof.pageStart >= 0 && proof.pageStart <= 1 &&
    proof.pageEnd >= 0 && proof.pageEnd <= 1 && proof.pageEnd >= proof.pageStart &&
    proof.lastFraction >= 0 && proof.lastFraction <= 1 &&
    proof.postedPercentage >= 0 && proof.postedPercentage <= 100 &&
    proof.visibleRoundedPercentage >= 0 && proof.visibleRoundedPercentage <= 100 &&
    proof.sectionEnd > proof.sectionStart && proof.sectionWeight > 0 &&
    typeof proof.lastCfi === 'string' && /^epubcfi\(/.test(proof.lastCfi) &&
    proof.scrolled === false && proof.anchorContained === true &&
    proof.targetContained === true &&
    proof.targetFraction === proof.requestedPercentage / 100 &&
    proof.visibleSection === proof.resolvedSection &&
    proof.expectedPage === Math.round(proof.resolvedAnchor * (proof.textPages - 1)) &&
    proof.contentPage === proof.expectedPage &&
    proof.anchorStart === (proof.textPages === 1 || proof.contentPage === 0
      ? 0 : (proof.contentPage - 0.5) / (proof.textPages - 1)) &&
    proof.anchorEnd === (proof.textPages === 1 || proof.contentPage === proof.textPages - 1
      ? 1 : (proof.contentPage + 0.5) / (proof.textPages - 1)) &&
    proof.anchorEndInclusive === (proof.contentPage === proof.textPages - 1) &&
    proof.resolvedAnchor >= proof.anchorStart &&
    (proof.anchorEndInclusive
      ? proof.resolvedAnchor <= proof.anchorEnd
      : proof.resolvedAnchor < proof.anchorEnd) &&
    proof.sectionWeight === proof.sectionEnd - proof.sectionStart &&
    proof.pageStart === proof.sectionStart +
      proof.contentPage / proof.textPages * proof.sectionWeight &&
    proof.pageEnd === proof.pageStart + proof.sectionWeight / proof.textPages &&
    proof.reportedPageContainsRequestedFraction ===
      (proof.targetFraction >= proof.pageStart && proof.targetFraction <= proof.pageEnd) &&
    proof.reportedPageContainsLastFraction ===
      (proof.lastFraction >= proof.pageStart && proof.lastFraction <= proof.pageEnd) &&
    proof.lastCfi === progress.cfi &&
    proof.postedPercentage === Number(progress.percentage) &&
    proof.postedPercentage === proof.lastFraction * 100 &&
    proof.visibleRoundedPercentage === Math.round(proof.postedPercentage);
}

function sessionCheckpointIsExact(item) {
  const posted = item.postedSession;
  const listed = item.listedSession;
  if (!hasExactKeys(posted, postedSessionFields) || !hasExactKeys(listed, listedSessionFields)) {
    return false;
  }
  const start = Date.parse(posted.startTime);
  const end = Date.parse(posted.endTime);
  const createdAt = parseServerLocalDateTime(listed.createdAt);
  const baselineIds = item.baselineSessionIds;
  const opening = item.openingProgressPost;
  const go = item.goProgressPost;
  const ending = item.endProgressPost;
  const bounds = item.lifecycleBounds;
  const stationary = item.stationaryEvidence;
  const expectedDelta = roundedReadingSessionProgress(
    roundedReadingSessionProgress(ending?.percentage) - Number(opening?.percentage));
  const correspondingFields = [
    'bookType', 'durationSeconds', 'startProgress', 'endProgress', 'progressDelta',
    'startLocation', 'endLocation'
  ];
  return item.sessionId !== null && item.sessionId !== undefined &&
    Array.isArray(baselineIds) &&
    !new Set(baselineIds.map(value => String(value))).has(String(item.sessionId)) &&
    posted.bookId === item.serverBookId && listed.bookId === item.serverBookId &&
    listed.id === item.sessionId &&
    posted.bookType === 'EPUB' && listed.bookType === 'EPUB' &&
    typeof listed.bookTitle === 'string' && listed.bookTitle.length > 0 &&
    Number.isFinite(start) && Number.isFinite(end) && end >= start &&
    new Date(start).toISOString() === posted.startTime &&
    new Date(end).toISOString() === posted.endTime &&
    Number.isFinite(createdAt) &&
    !!bounds && Number.isFinite(bounds.openingActionNotBefore) &&
    Number.isFinite(bounds.openingProgressObservedNotAfter) &&
    Number.isFinite(bounds.closedNotBefore) &&
    Number.isFinite(bounds.closedNotAfter) &&
    bounds.openingActionNotBefore <= start &&
    start <= bounds.openingProgressObservedNotAfter &&
    bounds.openingProgressObservedNotAfter <= bounds.closedNotBefore &&
    bounds.closedNotBefore <= end && end <= bounds.closedNotAfter &&
    Number.isInteger(posted.durationSeconds) && posted.durationSeconds >= 30 &&
    posted.durationSeconds === Math.floor((end - start) / 1000) &&
    posted.durationSeconds >= Math.floor(
      (bounds.closedNotBefore - bounds.openingProgressObservedNotAfter) / 1000) &&
    posted.durationSeconds <= Math.ceil(
      (bounds.closedNotAfter - bounds.openingActionNotBefore) / 1000) &&
    posted.durationFormatted === formattedReadingSessionDuration(posted.durationSeconds) &&
    progressWasExactlyPersisted(opening, item.openingPersistedProgress) &&
    progressWasExactlyPersisted(ending, item.endPersistedProgress) &&
    posted.startLocation === opening.cfi &&
    posted.endLocation === ending.cfi &&
    posted.startProgress === roundedReadingSessionProgress(opening.percentage) &&
    posted.endProgress === roundedReadingSessionProgress(ending.percentage) &&
    posted.progressDelta === expectedDelta &&
    listed.startTime === persistedReadingSessionTimestamp(posted.startTime) &&
    listed.endTime === persistedReadingSessionTimestamp(posted.endTime) &&
    correspondingFields.every(field => listed[field] === posted[field]) &&
    !!go && /^epubcfi\(/.test(go.cfi || '') && Number.isFinite(Number(go.percentage)) &&
    go.cfi !== opening.cfi && Number(go.percentage) !== Number(opening.percentage) &&
    !!stationary && Number.isInteger(stationary.durationMs) && stationary.durationMs >= 31_000 &&
    Number.isInteger(stationary.progressPostCountBefore) &&
    Number.isInteger(stationary.progressPostCountAfter) &&
    stationary.progressPostCountBefore >= 0 &&
    stationary.progressPostCountAfter === stationary.progressPostCountBefore &&
    ['Next Section', 'Previous Section'].includes(item.endNavigationControl) &&
    ending.cfi !== go.cfi && Number(ending.percentage) !== Number(go.percentage) &&
    goProofIsExact(item.goTargetContainment, {
      cfi: go.cfi,
      percentage: go.percentage
    });
}

const args = process.argv.slice(2);
let runtimeFile;
let checkpointFile;
for (let index = 0; index < args.length; index += 1) {
  if (args[index] === '--runtime') runtimeFile = args[++index];
  else if (args[index] === '--checkpoints') checkpointFile = args[++index];
  else usage(`unknown argument ${args[index]}`);
}
if (!runtimeFile || !checkpointFile) usage('--runtime and --checkpoints are required');
runtimeFile = path.resolve(runtimeFile);
checkpointFile = path.resolve(checkpointFile);
if (!fs.existsSync(runtimeFile)) usage('runtime does not exist');
if (!fs.existsSync(checkpointFile)) usage('checkpoint artifact does not exist');

const runtime = JSON.parse(fs.readFileSync(runtimeFile, 'utf8'));
const artifact = JSON.parse(fs.readFileSync(checkpointFile, 'utf8'));
const producer = (artifact.checkpoints || []).filter(item => item.journey === 'web-to-koreader-producer');
const sessions = (artifact.checkpoints || []).filter(item => item.journey === 'web-reader-reading-session');
if (artifact.schemaVersion !== 2) fail('checkpoint artifact must use schemaVersion 2');
if (sessions.length !== 0 && sessions.length !== 9) {
  fail(`reading-session checkpoint set must be empty or complete, found ${sessions.length}`);
}
if (new Set(sessions.map(item => item.alias)).size !== sessions.length) {
  fail('reading-session checkpoint aliases must be unique');
}
if (new Set(sessions.map(item => String(item.sessionId))).size !== sessions.length) {
  fail('reading-session checkpoint IDs must be unique');
}
for (const item of sessions) {
  if (!sessionCheckpointIsExact(item)) {
    fail('every reading-session checkpoint must contain one exact newly persisted session');
  }
}
if (producer.length !== 9) fail(`expected 9 producer checkpoints, found ${producer.length}`);
if (new Set(producer.map(item => item.alias)).size !== 9) fail('producer checkpoint aliases must be unique');
if (producer.filter(item => item.kind === 'synthetic').length !== 1) fail('producer requires one synthetic checkpoint');
if (producer.filter(item => item.kind === 'private').length !== 8) fail('producer requires eight private checkpoints');
for (const item of producer) {
  if (item.annotation?.selectionMethod !== 'physical-mouse-drag') {
    fail('every producer checkpoint must record physical-mouse-drag selection');
  }
  if (!['already-at-exact-persisted-eof', 'moved-to-exact-persisted-eof']
    .includes(item.eofPreparation)) {
    fail('every producer checkpoint must record an exact EOF preparation method');
  }
  const eof = item.eofSetup || {};
  if (eof.eofPreparation !== item.eofPreparation || eof.visiblePercentage !== 100 ||
      eof.sliderValue !== 100 || eof.nextSectionDisabled !== true ||
      eof.persistedPercentage !== 100 || !/^epubcfi\(/.test(eof.persistedCfi || '') ||
      !Object.hasOwn(eof, 'persistedHref')) {
    fail('every producer checkpoint must prove exact visible and persisted EOF');
  }
  if (item.eofPreparation === 'moved-to-exact-persisted-eof' &&
      !goProofIsExact(eof.goTargetContainment, {
        cfi: eof.persistedCfi,
        percentage: eof.persistedPercentage
      })) {
    fail('moved EOF preparation must prove exact Foliate target containment');
  }
  if (!goProofIsExact(item.progress?.goTargetContainment, item.progress || {})) {
    fail('every producer checkpoint must prove exact final Foliate target containment');
  }
}

async function request(baseUrl, route, token) {
  const response = await fetch(`${baseUrl.replace(/\/$/, '')}${route}`, {
    headers: token ? { Authorization: `Bearer ${token}`, Accept: 'application/json' } : {
      Accept: 'application/json'
    }
  });
  if (!response.ok) fail(`read-only server verification received HTTP ${response.status}`);
  return response.json();
}

async function main() {
  const baseUrl = String(runtime.baseUrl || '').replace(/\/$/, '');
  const login = await fetch(`${baseUrl}/api/v1/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ username: runtime.username, password: runtime.password })
  });
  if (!login.ok) fail(`login received HTTP ${login.status}`);
  const token = (await login.json()).accessToken;
  if (!token) fail('login did not return an access token');

  for (let index = 0; index < producer.length; index += 1) {
    const expected = producer[index];
    const label = expected.kind === 'synthetic' ? 'synthetic' : `private-${index}`;
    const progress = await request(baseUrl, `/api/v1/app/books/${expected.serverBookId}/progress`, token);
    if (progress.epubProgress?.cfi !== expected.progress.cfi) fail(`${label} progress CFI differs from checkpoint`);
    if (Number(progress.epubProgress?.percentage) !==
        progressPercentageAtServerPrecision(expected.progress.percentage)) {
      fail(`${label} progress percentage differs from checkpoint`);
    }
    if ((progress.epubProgress?.href ?? null) !== (expected.progress.href ?? null)) {
      fail(`${label} progress href differs from checkpoint`);
    }
    const annotations = await request(baseUrl, `/api/v1/annotations/book/${expected.serverBookId}`, token);
    if (!Array.isArray(annotations) || annotations.length !== 1) {
      fail(`${label} must have exactly one producer-owned server annotation`);
    }
    const actual = annotations[0];
    for (const field of ['id', 'cfi', 'text', 'color', 'style', 'note']) {
      const actualValue = actual[field] ?? null;
      const expectedValue = expected.annotation[field] ?? null;
      if (actualValue !== expectedValue) fail(`${label} annotation ${field} differs from checkpoint`);
    }
  }
  for (const expected of sessions) {
    const response = await request(baseUrl,
      `/api/v1/reading-sessions/book/${expected.serverBookId}?page=0&size=100`, token);
    const rows = Array.isArray(response) ? response : response?.content;
    if (!Array.isArray(rows)) fail(`${expected.alias} reading sessions are not paged content`);
    const identified = rows.filter(item => String(item.id) === String(expected.sessionId));
    if (identified.length !== 1) {
      fail(`${expected.alias} must contain exactly one checkpoint session ID`);
    }
    const actual = identified[0];
    if (!hasExactKeys(actual, listedSessionFields)) {
      fail(`${expected.alias} live session does not have the exact listed DTO shape`);
    }
    for (const field of listedSessionFields) {
      if (actual[field] !== expected.listedSession[field]) {
        fail(`${expected.alias} session ${field} differs from checkpoint`);
      }
    }
  }
  console.log('web reader checkpoint verification passed: 9/9 exact progress and annotations' +
    (sessions.length ? '; 9/9 exact reading sessions' : ''));
}

main().catch(error => {
  console.error(`verify-web-reader-checkpoints: ${error.message}`);
  process.exitCode = 1;
});
