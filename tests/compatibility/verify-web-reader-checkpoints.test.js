const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { after, before, test } = require('node:test');

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'grimmory-checkpoint-verifier-'));
const runtimeFile = path.join(temporary, 'runtime.json');
const checkpointFile = path.join(temporary, 'checkpoints.json');
const serverState = new Map();
let server;

function exactGoProof(requestedPercentage, cfi) {
  const targetFraction = requestedPercentage / 100;
  const resolvedAnchor = targetFraction;
  const textPages = 10;
  const contentPage = Math.round(targetFraction * (textPages - 1));
  const pageStart = contentPage / textPages;
  const pageEnd = pageStart + 1 / textPages;
  const anchorStart = contentPage === 0 ? 0 : (contentPage - 0.5) / (textPages - 1);
  const anchorEnd = contentPage === textPages - 1 ? 1 : (contentPage + 0.5) / (textPages - 1);
  const anchorEndInclusive = contentPage === textPages - 1;
  return {
    requestedPercentage,
    targetFraction,
    resolvedSection: 0,
    visibleSection: 0,
    resolvedAnchor,
    textPages,
    contentPage,
    expectedPage: contentPage,
    sectionStart: 0,
    sectionEnd: 1,
    sectionWeight: 1,
    pageStart,
    pageEnd,
    anchorStart,
    anchorEnd,
    anchorEndInclusive,
    anchorContained: resolvedAnchor >= anchorStart &&
      (anchorEndInclusive ? resolvedAnchor <= anchorEnd : resolvedAnchor < anchorEnd),
    targetContained: true,
    reportedPageContainsRequestedFraction:
      targetFraction >= pageStart && targetFraction <= pageEnd,
    reportedPageContainsLastFraction: true,
    lastFraction: pageEnd,
    lastCfi: cfi,
    scrolled: false,
    postedPercentage: pageEnd * 100,
    visibleRoundedPercentage: Math.round(pageEnd * 100)
  };
}

function producerCheckpoint(index) {
  const alias = index === 0 ? 'synthetic' : `real-${1000 + index}`;
  const progressCfi = `epubcfi(/6/${index + 2}!/4/2:0)`;
  const progress = { percentage: 70, cfi: progressCfi };
  progress.goTargetContainment = exactGoProof(70, progressCfi);
  const annotation = {
    id: index + 10,
    cfi: `epubcfi(/6/${index + 2}!/4/4:0)`,
    text: `Synthetic verification text ${index}`,
    color: '#FFFF00',
    style: 'highlight',
    note: null,
    selectionMethod: 'physical-mouse-drag'
  };
  serverState.set(index + 1, { progress, annotation });
  return {
    journey: 'web-to-koreader-producer',
    kind: index === 0 ? 'synthetic' : 'private',
    alias,
    serverBookId: index + 1,
    eofPreparation: 'moved-to-exact-persisted-eof',
    eofSetup: {
      eofPreparation: 'moved-to-exact-persisted-eof',
      visiblePercentage: 100,
      sliderValue: 100,
      nextSectionDisabled: true,
      persistedPercentage: 100,
      persistedCfi: `epubcfi(/6/${index + 2}!/4/2:99)`,
      persistedHref: null,
      goTargetContainment: exactGoProof(100, `epubcfi(/6/${index + 2}!/4/2:99)`)
    },
    progress,
    annotation
  };
}

function readingSessionCheckpoint(index) {
  const alias = index === 0 ? 'synthetic' : `real-${1000 + index}`;
  const startLocation = `epubcfi(/6/${index + 2}!/4/2:0)`;
  const goLocation = `epubcfi(/6/${index + 2}!/4/6:0)`;
  const endLocation = `epubcfi(/6/${index + 2}!/4/8:0)`;
  const openingProgressPost = { cfi: startLocation, href: `chapter-${index}-open.xhtml`, percentage: 90.123 };
  const openingPersistedProgress = { ...openingProgressPost, percentage: 90.123 };
  const goTargetContainment = exactGoProof(40, goLocation);
  const goProgressPost = {
    cfi: goLocation,
    href: `chapter-${index}-go.xhtml`,
    percentage: goTargetContainment.postedPercentage
  };
  const endProgressPost = { cfi: endLocation, href: `chapter-${index}-end.xhtml`, percentage: 70.456 };
  const endPersistedProgress = { ...endProgressPost, percentage: 70.456 };
  const start = new Date(Date.UTC(2026, 7, 10, 10, index, 0, 477));
  const end = new Date(start.getTime() + 31_000);
  const postedSession = {
    bookId: index + 1,
    bookType: 'EPUB',
    startTime: start.toISOString(),
    endTime: end.toISOString(),
    durationSeconds: 31,
    durationFormatted: '31s',
    startProgress: 90.12,
    endProgress: 70.46,
    progressDelta: -19.66,
    startLocation,
    endLocation
  };
  const listedSession = {
    id: index + 2000,
    bookId: index + 1,
    bookTitle: `Exact fixture book ${index}`,
    bookType: 'EPUB',
    startTime: start.toISOString().replace('.477Z', 'Z'),
    endTime: end.toISOString().replace('.477Z', 'Z'),
    durationSeconds: 31,
    startProgress: 90.12,
    endProgress: 70.46,
    progressDelta: -19.66,
    startLocation,
    endLocation,
    createdAt: new Date(end.getTime() + 50).toISOString()
  };
  const checkpoint = {
    journey: 'web-reader-reading-session',
    kind: index === 0 ? 'synthetic' : 'private',
    alias,
    serverBookId: index + 1,
    sessionId: listedSession.id,
    baselineSessionIds: [index + 1000],
    openingProgressPost,
    openingPersistedProgress,
    goProgressPost,
    stationaryEvidence: {
      durationMs: 31_000,
      progressPostCountBefore: 2,
      progressPostCountAfter: 2
    },
    endNavigationControl: 'Next Section',
    endProgressPost,
    endPersistedProgress,
    lifecycleBounds: {
      openingActionNotBefore: start.getTime() - 1000,
      openingProgressObservedNotAfter: start.getTime() + 20,
      closedNotBefore: end.getTime() - 1000,
      closedNotAfter: end.getTime() + 1000
    },
    postedSession,
    listedSession,
    goTargetContainment
  };
  serverState.get(index + 1).session = { ...listedSession };
  return checkpoint;
}

function runVerifier() {
  return new Promise(resolve => {
    const child = spawn(process.execPath, [
      path.join(__dirname, 'verify-web-reader-checkpoints.js'),
      '--runtime', runtimeFile,
      '--checkpoints', checkpointFile
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('close', code => resolve({ code, stdout, stderr }));
  });
}

before(async () => {
  const producer = Array.from({ length: 9 }, (_, index) => producerCheckpoint(index));
  const sessions = Array.from({ length: 9 }, (_, index) => readingSessionCheckpoint(index));
  const checkpoints = [...producer, ...sessions];
  fs.writeFileSync(checkpointFile, JSON.stringify({ schemaVersion: 2, checkpoints }));
  server = http.createServer((request, response) => {
    response.setHeader('Content-Type', 'application/json');
    if (request.method === 'POST' && request.url === '/api/v1/auth/login') {
      response.end(JSON.stringify({ accessToken: 'test-token' }));
      return;
    }
    const progress = /^\/api\/v1\/app\/books\/(\d+)\/progress$/.exec(request.url || '');
    if (request.method === 'GET' && progress) {
      const state = serverState.get(Number(progress[1]));
      response.end(JSON.stringify({ epubProgress: state.progress }));
      return;
    }
    const annotations = /^\/api\/v1\/annotations\/book\/(\d+)$/.exec(request.url || '');
    if (request.method === 'GET' && annotations) {
      const state = serverState.get(Number(annotations[1]));
      response.end(JSON.stringify([state.annotation]));
      return;
    }
    const sessions = /^\/api\/v1\/reading-sessions\/book\/(\d+)(?:\?.*)?$/.exec(
      request.url || '');
    if (request.method === 'GET' && sessions) {
      const state = serverState.get(Number(sessions[1]));
      response.end(JSON.stringify({ content: [state.session] }));
      return;
    }
    response.statusCode = 404;
    response.end(JSON.stringify({ error: 'not found' }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  fs.writeFileSync(runtimeFile, JSON.stringify({
    baseUrl: `http://127.0.0.1:${server.address().port}`,
    username: 'test-user',
    password: 'test-password'
  }));
});

after(async () => {
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(temporary, { recursive: true });
});

test('accepts the exact nine-book live producer state', async () => {
  const result = await runVerifier();
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /9\/9 exact progress and annotations/);
});

test('rejects a stale live CFI before KOReader can consume it', async () => {
  const original = serverState.get(1).progress.cfi;
  serverState.get(1).progress.cfi = 'epubcfi(/6/999!/4/2:0)';
  const result = await runVerifier();
  serverState.get(1).progress.cfi = original;
  assert.equal(result.code, 1);
  assert.match(result.stderr, /progress CFI differs from checkpoint/);

  const originalDelta = serverState.get(1).session.progressDelta;
  serverState.get(1).session.progressDelta = originalDelta + 0.00005;
  const sessionResult = await runVerifier();
  serverState.get(1).session.progressDelta = originalDelta;
  assert.equal(sessionResult.code, 1);
  assert.match(sessionResult.stderr, /session progressDelta differs from checkpoint/);

  const artifact = JSON.parse(fs.readFileSync(checkpointFile, 'utf8'));
  const firstSession = artifact.checkpoints.find(item =>
    item.journey === 'web-reader-reading-session' && item.serverBookId === 1);
  const originalStartLocation = firstSession.postedSession.startLocation;
  firstSession.postedSession.startLocation = firstSession.goProgressPost.cfi;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const conflatedStartResult = await runVerifier();
  firstSession.postedSession.startLocation = originalStartLocation;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  assert.equal(conflatedStartResult.code, 1);
  assert.match(conflatedStartResult.stderr, /exact newly persisted session/);

  const exactEndCfi = firstSession.endProgressPost.cfi;
  firstSession.endProgressPost.cfi = firstSession.goProgressPost.cfi;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const staleEndResult = await runVerifier();
  firstSession.endProgressPost.cfi = exactEndCfi;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  assert.equal(staleEndResult.code, 1);
  assert.match(staleEndResult.stderr, /exact newly persisted session/);

  const exactEndControl = firstSession.endNavigationControl;
  firstSession.endNavigationControl = 'ArrowRight';
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const internalNavigationResult = await runVerifier();
  firstSession.endNavigationControl = exactEndControl;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  assert.equal(internalNavigationResult.code, 1);
  assert.match(internalNavigationResult.stderr, /exact newly persisted session/);

  const exactStationaryEvidence = { ...firstSession.stationaryEvidence };
  firstSession.stationaryEvidence.durationMs = 30_999;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const shortStationaryResult = await runVerifier();
  assert.equal(shortStationaryResult.code, 1);
  assert.match(shortStationaryResult.stderr, /exact newly persisted session/);
  firstSession.stationaryEvidence = {
    ...exactStationaryEvidence,
    progressPostCountAfter: exactStationaryEvidence.progressPostCountBefore + 1
  };
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const mutatingStationaryResult = await runVerifier();
  firstSession.stationaryEvidence = exactStationaryEvidence;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  assert.equal(mutatingStationaryResult.code, 1);
  assert.match(mutatingStationaryResult.stderr, /exact newly persisted session/);

  const exactLifecycleBounds = { ...firstSession.lifecycleBounds };
  const postedStartEpoch = Date.parse(firstSession.postedSession.startTime);
  firstSession.lifecycleBounds.openingProgressObservedNotAfter = postedStartEpoch - 1;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const lateStartResult = await runVerifier();
  assert.equal(lateStartResult.code, 1);
  assert.match(lateStartResult.stderr, /exact newly persisted session/);
  firstSession.lifecycleBounds = {
    ...exactLifecycleBounds,
    openingActionNotBefore: postedStartEpoch + 1
  };
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const earlyStartResult = await runVerifier();
  firstSession.lifecycleBounds = exactLifecycleBounds;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  assert.equal(earlyStartResult.code, 1);
  assert.match(earlyStartResult.stderr, /exact newly persisted session/);

  const exactListedStart = firstSession.listedSession.startTime;
  const invalidListedStarts = [
    new Date(Date.parse(exactListedStart) + 1000).toISOString().replace('.000Z', 'Z'),
    exactListedStart.replace(/Z$/, '+00:00'),
    'not-a-timestamp',
    exactListedStart.replace(/Z$/, '.477Z'),
    exactListedStart.replace(/Z$/, '.123Z')
  ];
  for (const invalidStart of invalidListedStarts) {
    firstSession.listedSession.startTime = invalidStart;
    fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
    const timestampResult = await runVerifier();
    assert.equal(timestampResult.code, 1);
    assert.match(timestampResult.stderr, /exact newly persisted session/);
  }
  firstSession.listedSession.startTime = exactListedStart;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));

  serverState.get(1).session.unexpected = 'must not be accepted';
  const extraFieldResult = await runVerifier();
  delete serverState.get(1).session.unexpected;
  assert.equal(extraFieldResult.code, 1);
  assert.match(extraFieldResult.stderr, /exact listed DTO shape/);
});

test('accepts the pinned MariaDB FLOAT representation of browser percentage', async () => {
  const artifact = JSON.parse(fs.readFileSync(checkpointFile, 'utf8'));
  const originalCheckpoint = artifact.checkpoints[0].progress.percentage;
  const originalProof = artifact.checkpoints[0].progress.goTargetContainment;
  const originalServer = serverState.get(1).progress.percentage;
  const postedPercentage = 5.552153709033263;
  const lastFraction = postedPercentage / 100;
  const sectionWeight = lastFraction * 10 / 6;
  const resolvedAnchor = 0.055 / sectionWeight;
  const anchorStart = (5 - 0.5) / 9;
  const anchorEnd = (5 + 0.5) / 9;
  artifact.checkpoints[0].progress.percentage = postedPercentage;
  artifact.checkpoints[0].progress.goTargetContainment = {
    requestedPercentage: 5.5,
    targetFraction: 0.055,
    resolvedSection: 0,
    visibleSection: 0,
    resolvedAnchor,
    textPages: 10,
    contentPage: 5,
    expectedPage: 5,
    sectionStart: 0,
    sectionEnd: sectionWeight,
    sectionWeight,
    pageStart: 5 / 10 * sectionWeight,
    pageEnd: lastFraction,
    anchorStart,
    anchorEnd,
    anchorEndInclusive: false,
    anchorContained: resolvedAnchor >= anchorStart && resolvedAnchor < anchorEnd,
    targetContained: true,
    reportedPageContainsRequestedFraction: true,
    reportedPageContainsLastFraction: true,
    lastFraction,
    lastCfi: artifact.checkpoints[0].progress.cfi,
    scrolled: false,
    postedPercentage,
    visibleRoundedPercentage: 6
  };
  serverState.get(1).progress.percentage = 5.55215;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const result = await runVerifier();
  artifact.checkpoints[0].progress.percentage = originalCheckpoint;
  artifact.checkpoints[0].progress.goTargetContainment = originalProof;
  serverState.get(1).progress.percentage = originalServer;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  assert.equal(result.code, 0, result.stderr);
});

test('accepts the exact real EPUB inverse-rounding snap-cell proof', async () => {
  const artifact = JSON.parse(fs.readFileSync(checkpointFile, 'utf8'));
  const originalCheckpoint = artifact.checkpoints[0].progress;
  const originalServer = serverState.get(1).progress;
  const cfi = 'epubcfi(/6/178!/4/2/2[id109],/72,/158/5:108)';
  const postedPercentage = 80.20244378595966;
  artifact.checkpoints[0].progress = {
    cfi,
    percentage: postedPercentage,
    goTargetContainment: {
      requestedPercentage: 80,
      targetFraction: 0.8,
      resolvedSection: 88,
      visibleSection: 88,
      resolvedAnchor: 0.22818388800081543,
      textPages: 4,
      contentPage: 1,
      expectedPage: 1,
      sectionStart: 0.7983005271526361,
      sectionEnd: 0.8057483485665569,
      sectionWeight: 0.007447821413920752,
      pageStart: 0.8001624825061163,
      pageEnd: 0.8020244378595965,
      anchorStart: 1 / 6,
      anchorEnd: 0.5,
      anchorEndInclusive: false,
      anchorContained: true,
      targetContained: true,
      reportedPageContainsRequestedFraction: false,
      reportedPageContainsLastFraction: true,
      lastFraction: 0.8020244378595965,
      lastCfi: cfi,
      scrolled: false,
      postedPercentage,
      visibleRoundedPercentage: 80
    }
  };
  serverState.get(1).progress = { cfi, percentage: 80.2024 };
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const result = await runVerifier();
  artifact.checkpoints[0].progress = originalCheckpoint;
  serverState.get(1).progress = originalServer;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  assert.equal(result.code, 0, result.stderr);
});

test('rejects a producer checkpoint without the exact EOF oracle', async () => {
  const artifact = JSON.parse(fs.readFileSync(checkpointFile, 'utf8'));
  const original = artifact.checkpoints[0].eofSetup.nextSectionDisabled;
  artifact.checkpoints[0].eofSetup.nextSectionDisabled = false;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const result = await runVerifier();
  artifact.checkpoints[0].eofSetup.nextSectionDisabled = original;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  assert.equal(result.code, 1);
  assert.match(result.stderr, /exact visible and persisted EOF/);
});

test('rejects producer Go evidence when the resolver anchor falls outside its page snap cell', async () => {
  const artifact = JSON.parse(fs.readFileSync(checkpointFile, 'utf8'));
  const original = artifact.checkpoints[0].progress.goTargetContainment.resolvedAnchor;
  artifact.checkpoints[0].progress.goTargetContainment.resolvedAnchor =
    artifact.checkpoints[0].progress.goTargetContainment.anchorEnd;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const result = await runVerifier();
  artifact.checkpoints[0].progress.goTargetContainment.resolvedAnchor = original;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  assert.equal(result.code, 1);
  assert.match(result.stderr, /exact final Foliate target containment/);
});

test('rejects producer Go evidence when the rendered page differs from the resolved page', async () => {
  const artifact = JSON.parse(fs.readFileSync(checkpointFile, 'utf8'));
  const original = artifact.checkpoints[0].progress.goTargetContainment.contentPage;
  artifact.checkpoints[0].progress.goTargetContainment.contentPage = original - 1;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const result = await runVerifier();
  artifact.checkpoints[0].progress.goTargetContainment.contentPage = original;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  assert.equal(result.code, 1);
  assert.match(result.stderr, /exact final Foliate target containment/);
});

test('rejects impossible pagination geometry before accepting Go evidence', async () => {
  const artifact = JSON.parse(fs.readFileSync(checkpointFile, 'utf8'));
  const original = artifact.checkpoints[0].progress.goTargetContainment.textPages;
  artifact.checkpoints[0].progress.goTargetContainment.textPages = 0;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const emptyResult = await runVerifier();
  assert.equal(emptyResult.code, 1);
  assert.match(emptyResult.stderr, /exact final Foliate target containment/);

  artifact.checkpoints[0].progress.goTargetContainment.textPages = original;
  artifact.checkpoints[0].progress.goTargetContainment.contentPage = 1.5;
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  const fractionalResult = await runVerifier();
  artifact.checkpoints[0] = producerCheckpoint(0);
  fs.writeFileSync(checkpointFile, JSON.stringify(artifact));
  assert.equal(fractionalResult.code, 1);
  assert.match(fractionalResult.stderr, /exact final Foliate target containment/);
});
