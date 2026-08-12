#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('@playwright/test');
const { loginThroughUi } = require('./browser_helpers');
const {
  assertCoverFingerprint,
  assertProviderCopyPersisted,
  coverVisualFingerprint
} = require('./metadata_exactness');
const REPOSITORY_ROOT = path.resolve(__dirname, '../..');

function fail(message) {
  throw new Error(message);
}

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    fail(`${label} is not valid readable JSON`);
  }
}

function canonicalProvider(value) {
  return String(value || '').toLowerCase().replace(/[^a-z0-9]/g, '');
}

function requiredText(value, label) {
  if (typeof value !== 'string' || !value.trim()) fail(`${label} is required`);
  return value.trim();
}

function parseArguments(argv) {
  const options = { headful: false, allowRefresh: false, validatePlanOnly: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--runtime') options.runtime = argv[++index];
    else if (argument === '--plan') options.plan = argv[++index];
    else if (argument === '--evidence-output') options.evidenceOutput = argv[++index];
    else if (argument === '--diagnostics') options.diagnostics = argv[++index];
    else if (argument === '--headful') options.headful = true;
    else if (argument === '--allow-provider-network-refresh') options.allowRefresh = true;
    else if (argument === '--validate-plan-only') options.validatePlanOnly = true;
    else fail('unknown metadata refresh argument');
  }
  options.runtime = path.resolve(requiredText(options.runtime, '--runtime'));
  options.plan = path.resolve(requiredText(options.plan, '--plan'));
  requirePrivatePath(options.plan, 'plan');
  if (!options.validatePlanOnly) {
    options.evidenceOutput = path.resolve(requiredText(options.evidenceOutput, '--evidence-output'));
    requirePrivatePath(options.evidenceOutput, 'evidence output');
    if (!options.allowRefresh) {
      fail('provider refresh is disabled; pass --allow-provider-network-refresh explicitly');
    }
  }
  options.diagnostics = path.resolve(options.diagnostics || path.join(
    path.dirname(options.evidenceOutput || options.plan), 'metadata-refresh-diagnostics'
  ));
  requirePrivatePath(options.diagnostics, 'diagnostics');
  return options;
}

function requirePrivatePath(target, label) {
  const relative = path.relative(REPOSITORY_ROOT, target);
  if (relative.startsWith('..') || path.isAbsolute(relative)) return;
  const normalized = relative.replace(/\\/g, '/');
  if (normalized === 'build' || normalized.startsWith('build/') ||
      normalized === 'tests/compatibility/private' ||
      normalized.startsWith('tests/compatibility/private/')) return;
  fail(`${label} inside the repository must be below ignored build/ or tests/compatibility/private/`);
}

function runtimeBooks(runtime) {
  if (!Array.isArray(runtime.books)) fail('runtime books[] is required');
  return runtime.books.filter(book => {
    const kind = String(book.kind || '').toLowerCase();
    return kind === 'private' || kind === 'real' || kind === 'private-real-epub';
  });
}

function validatePlan(runtime, plan) {
  if (plan.schemaVersion !== 1 || !Array.isArray(plan.books)) {
    fail('metadata refresh plan must use schemaVersion 1 and books[]');
  }
  const privateBooks = runtimeBooks(runtime);
  const bySource = new Map();
  for (const item of plan.books) {
    const sourceSha256 = requiredText(item?.sourceSha256, 'plan source identity');
    if (bySource.has(sourceSha256)) fail('metadata refresh plan contains a duplicate source identity');
    const query = item?.query;
    if (!query || typeof query !== 'object' || Array.isArray(query)) {
      fail('metadata refresh plan has an invalid query');
    }
    const title = requiredText(query.title, 'plan query title');
    const author = requiredText(query.author, 'plan query author');
    const isbn = query.isbn == null || query.isbn === '' ? null : requiredText(query.isbn, 'plan query ISBN');
    const provider = requiredText(item.provider, 'plan provider');
    const providerItemId = requiredText(String(item.providerItemId || ''), 'plan provider item identity');
    bySource.set(sourceSha256, {
      sourceSha256, query: { title, author, isbn }, provider, providerItemId
    });
  }
  if (privateBooks.length !== bySource.size) {
    fail('metadata refresh plan does not cover the runtime private library exactly');
  }
  return privateBooks.map((book, index) => {
    const sourceSha256 = requiredText(book.sourceSha256, 'runtime private source identity');
    const selection = bySource.get(sourceSha256);
    if (!selection) fail(`metadata refresh plan is missing private-${index + 1}`);
    bySource.delete(sourceSha256);
    return { book, selection, privateLabel: `private-${index + 1}` };
  });
}

function normalizedEvidenceQuery(query) {
  const parts = [query.title, query.author, query.isbn].filter(Boolean);
  return parts.map(value => value.replace(/\s+/g, ' ').trim()).join(' | ');
}

async function chooseOnlyProvider(page, provider, alias) {
  const control = page.locator('#metadata-search-providers');
  await control.waitFor({ state: 'visible' });
  await control.click();
  const overlay = page.locator('.p-multiselect-overlay:visible');
  await overlay.waitFor({ state: 'visible' });
  const options = overlay.getByRole('option');
  const states = await options.evaluateAll(rows => rows.map(row => ({
    label: (row.textContent || '').replace(/\s+/g, ' ').trim(),
    selected: row.getAttribute('aria-selected') === 'true'
  })));
  const target = canonicalProvider(provider);
  const targetIndexes = states.map((state, index) => ({ state, index }))
    .filter(({ state }) => canonicalProvider(state.label) === target)
    .map(({ index }) => index);
  if (targetIndexes.length !== 1) fail(`${alias}: planned provider is not uniquely available`);
  const targetIndex = targetIndexes[0];
  if (!states[targetIndex].selected) await options.nth(targetIndex).click();
  for (let index = 0; index < states.length; index += 1) {
    if (index !== targetIndex && states[index].selected) await options.nth(index).click();
  }
  const finalStates = await options.evaluateAll(rows => rows.map(row => ({
    label: (row.textContent || '').replace(/\s+/g, ' ').trim(),
    selected: row.getAttribute('aria-selected') === 'true'
  })));
  const selected = finalStates.filter(state => state.selected);
  if (selected.length !== 1 || canonicalProvider(selected[0].label) !== target) {
    fail(`${alias}: provider UI did not retain exactly one selection`);
  }
  await page.keyboard.press('Escape');
  await overlay.waitFor({ state: 'hidden' });
}

async function matchingResultIndexes(cards, provider, providerItemId) {
  return cards.evaluateAll((rows, target) => {
    const canonical = value => String(value || '').toLowerCase().replace(/[^a-z0-9]/g, '');
    const idFromUrl = (providerName, href) => {
      let url;
      try { url = new URL(href); } catch (_) { return null; }
      const segments = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
      const providerKey = canonical(providerName);
      if (providerKey === 'google') return url.searchParams.get('id');
      if (providerKey === 'comicvine') {
        const value = segments.find(segment => /^4050-/.test(segment));
        return value ? value.replace(/^4050-/, '') : null;
      }
      if (providerKey === 'lubimyczytac') {
        const marker = segments.indexOf('ksiazka');
        return marker >= 0 ? segments[marker + 1] : null;
      }
      return segments.at(-1) || null;
    };
    return rows.map((card, index) => {
      const providerNode = card.querySelector('.card-provider');
      const link = providerNode?.querySelector('a');
      const providerName = (link?.textContent || providerNode?.textContent || '').trim();
      const itemId = idFromUrl(providerName, link?.href || '');
      return canonical(providerName) === canonical(target.provider) &&
        String(itemId || '') === String(target.providerItemId) ? index : -1;
    }).filter(index => index >= 0);
  }, { provider, providerItemId });
}

function isSelectedProviderDetail(response, provider, providerItemId) {
  if (response.request().method() !== 'GET' || !response.url().includes('/api/v1/books/metadata/detail/')) {
    return false;
  }
  try {
    const segments = new URL(response.url()).pathname.split('/').filter(Boolean).map(decodeURIComponent);
    return canonicalProvider(segments.at(-2)) === canonicalProvider(provider) &&
      String(segments.at(-1)) === String(providerItemId);
  } catch (_) {
    return false;
  }
}

async function fixedCoverScreenshot(image, alias, label) {
  await image.waitFor({ state: 'visible', timeout: 180_000 });
  const natural = await image.evaluate(async node => {
    if (!node.complete || !node.naturalWidth) {
      await new Promise((resolve, reject) => {
        node.addEventListener('load', resolve, { once: true });
        node.addEventListener('error', () => reject(new Error('cover failed to load')), { once: true });
      });
    }
    node.style.setProperty('width', '240px', 'important');
    node.style.setProperty('height', '360px', 'important');
    node.style.setProperty('object-fit', 'contain', 'important');
    node.style.setProperty('background', '#fff', 'important');
    return { width: node.naturalWidth, height: node.naturalHeight };
  });
  const bytes = await image.screenshot({ animations: 'disabled' });
  if (!bytes?.length) fail(`${alias}: ${label} cover screenshot was empty`);
  if (!natural.width || !natural.height) fail(`${alias}: ${label} cover had invalid dimensions`);
  return { bytes, naturalAspectRatio: natural.width / natural.height };
}

async function persistedCoverScreenshot(page, bookId, alias) {
  const image = page.locator('img[data-metadata-exactness-cover="persisted"]');
  await page.evaluate(id => {
    document.querySelector('img[data-metadata-exactness-cover="persisted"]')?.remove();
    const node = document.createElement('img');
    node.dataset.metadataExactnessCover = 'persisted';
    node.alt = 'Persisted metadata cover verification';
    node.src = `/api/v1/media/book/${id}/cover?exactness=${Date.now()}`;
    node.style.cssText = 'position:fixed;left:16px;top:16px;z-index:2147483647';
    document.body.appendChild(node);
  }, bookId);
  try {
    return await fixedCoverScreenshot(image, alias, 'persisted');
  } finally {
    await image.evaluate(node => node.remove()).catch(() => undefined);
  }
}

async function liveBookMetadata(page, bookId, alias) {
  const result = await page.evaluate(async id => {
    const token = localStorage.getItem('accessToken_Internal');
    const response = await fetch(`/api/v1/books/${id}?withDescription=true`, {
      cache: 'no-store', headers: token ? { Authorization: `Bearer ${token}` } : {}
    });
    return { status: response.status, body: response.ok ? await response.json() : null };
  }, bookId);
  if (result.status !== 200 || !result.body?.metadata) {
    fail(`${alias}: full post-save book metadata was not readable`);
  }
  return result.body.metadata;
}

async function refreshOne(page, runtime, book, selection, privateLabel) {
  const alias = privateLabel;
  await page.getByRole('link', { name: /All Books/i }).click();
  await page.locator('.book-browser-container').waitFor({ state: 'visible' });
  if (await page.locator('app-book-table').count()) {
    await page.locator('a.toolbar-item').filter({ has: page.locator('i.pi-table') }).click();
    await page.locator('app-book-table').waitFor({ state: 'detached' });
  }
  const title = requiredText(book.expectedMetadata?.title || book.metadata?.title ||
    book.serverTitle || book.title || selection.query.title,
    `${alias} runtime title`);
  const libraryCards = page.locator('.book-card');
  await libraryCards.first().waitFor({ state: 'visible' });
  const cardIndex = await libraryCards.evaluateAll((items, expectedTitle) => items.findIndex(item =>
    (item.querySelector('.book-title')?.textContent || '').trim() === expectedTitle
  ), title);
  if (cardIndex < 0) fail(`${alias}: exact All Books card was not visible`);
  const card = libraryCards.nth(cardIndex);
  await card.scrollIntoViewIfNeeded();
  await card.hover();
  const detailsButton = card.getByRole('button', { name: 'View book details' });
  await detailsButton.waitFor({ state: 'visible' });
  await detailsButton.click();
  await page.locator('.metadata-viewer-container').waitFor({ state: 'visible' });
  const matchTab = page.locator('[role="tab"]').filter({ has: page.locator('i.pi-search') });
  await matchTab.waitFor({ state: 'visible' });
  await matchTab.click();
  const search = page.locator('.search-card');
  await search.waitFor({ state: 'visible' });
  await chooseOnlyProvider(page, selection.provider, alias);
  await search.locator('#metadata-search-title').fill(selection.query.title);
  await search.locator('#metadata-search-author').fill(selection.query.author);
  await search.locator('#metadata-search-isbn').fill(selection.query.isbn || '');
  await search.locator('button[type="submit"]').click();
  const status = page.locator('.provider-status');
  await status.waitFor({ state: 'visible', timeout: 180_000 });
  await status.locator('.fetching-badge').waitFor({ state: 'hidden', timeout: 180_000 });
  const cards = page.locator('.metadata-card');
  if (await cards.count() === 0) fail(`${alias}: provider search returned no results`);
  const matches = await matchingResultIndexes(cards, selection.provider, selection.providerItemId);
  if (matches.length !== 1) fail(`${alias}: provider result identity was missing or ambiguous`);
  const selectedDetailResponse = page.waitForResponse(response =>
    isSelectedProviderDetail(response, selection.provider, selection.providerItemId),
  { timeout: 180_000 });
  await cards.nth(matches[0]).click();
  const detailResponse = await selectedDetailResponse;
  if (!detailResponse.ok()) fail(`${alias}: selected provider detail request failed`);
  const detailBody = await detailResponse.json();
  const selectedMetadata = detailBody?.metadata || detailBody;
  if (!selectedMetadata || typeof selectedMetadata !== 'object' || Array.isArray(selectedMetadata)) {
    fail(`${alias}: selected provider detail was not a metadata object`);
  }
  const picker = page.locator('form.metadata-picker');
  await picker.waitFor({ state: 'visible' });
  await picker.locator('.detail-loading-banner').waitFor({ state: 'hidden', timeout: 180_000 });
  let selectedCoverFingerprint = null;
  if (selectedMetadata.thumbnailUrl) {
    const selectedCover = picker.locator('.field-side.fetched.cover-side img').first();
    const selectedCapture = await fixedCoverScreenshot(selectedCover, alias, 'selected provider');
    selectedCoverFingerprint = {
      ...coverVisualFingerprint(selectedCapture.bytes),
      aspectRatio: selectedCapture.naturalAspectRatio
    };
  }
  await picker.locator('.column-actions button').nth(1).click();
  await picker.locator('.transfer-btn.copied').first().waitFor({ state: 'visible' });
  const saved = page.waitForResponse(response =>
    response.request().method() === 'PUT' &&
    response.url().includes(`/api/v1/books/${book.serverBookId}/metadata`),
    { timeout: 180_000 }
  );
  await picker.locator('button[type="submit"]').click();
  const response = await saved;
  if (!response.ok()) fail(`${alias}: metadata save was rejected`);
  const outboundWrapper = response.request().postDataJSON();
  await picker.locator('.transfer-btn.saved').first().waitFor({ state: 'visible', timeout: 180_000 });
  const persistedMetadata = await liveBookMetadata(page, book.serverBookId, alias);
  const projectionEvidence = assertProviderCopyPersisted(
    selectedMetadata, outboundWrapper, persistedMetadata,
    selection.provider, selection.providerItemId
  );
  let coverEvidence = null;
  if (selectedCoverFingerprint) {
    const persistedCapture = await persistedCoverScreenshot(page, book.serverBookId, alias);
    const persistedCoverFingerprint = {
      ...coverVisualFingerprint(persistedCapture.bytes),
      aspectRatio: persistedCapture.naturalAspectRatio
    };
    coverEvidence = {
      selected: selectedCoverFingerprint,
      persisted: persistedCoverFingerprint,
      differenceHashDistance: assertCoverFingerprint(
        selectedCoverFingerprint, persistedCoverFingerprint)
    };
  }
  return {
    sourceSha256: selection.sourceSha256,
    provider: selection.provider,
    providerItemId: selection.providerItemId,
    query: normalizedEvidenceQuery(selection.query),
    selectedProjectionSha256: projectionEvidence.selectedProjectionSha256,
    persistedProjectionSha256: projectionEvidence.persistedProjectionSha256,
    coverVisualFingerprint: coverEvidence,
    selectedAt: new Date().toISOString()
  };
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const runtime = readJson(options.runtime, 'runtime');
  runtime.baseUrl = requiredText(runtime.baseUrl || runtime.url, 'runtime base URL');
  runtime.username = requiredText(runtime.username || runtime.credentials?.username, 'runtime username');
  runtime.password = requiredText(runtime.password || runtime.credentials?.password, 'runtime password');
  const plan = validatePlan(runtime, readJson(options.plan, 'metadata refresh plan'));
  if (options.validatePlanOnly) {
    console.log(`validated metadata refresh plan for ${plan.length} private books; no provider requests made`);
    return;
  }
  fs.mkdirSync(options.diagnostics, { recursive: true });
  const browser = await chromium.launch({ headless: !options.headful });
  const context = await browser.newContext({ locale: 'en-GB', timezoneId: 'Etc/UTC' });
  const page = await context.newPage();
  await context.tracing.start({ screenshots: true, snapshots: true });
  const evidence = [];
  let currentAlias = 'setup';
  try {
    await loginThroughUi(page, runtime);
    for (const { book, selection, privateLabel } of plan) {
      currentAlias = privateLabel;
      evidence.push(await refreshOne(page, runtime, book, selection, privateLabel));
      console.log(`refreshed metadata through Grimmory UI for ${currentAlias}`);
    }
    const document = { schemaVersion: 1, books: evidence };
    fs.mkdirSync(path.dirname(options.evidenceOutput), { recursive: true });
    const temporary = `${options.evidenceOutput}.tmp`;
    fs.writeFileSync(temporary, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600 });
    fs.renameSync(temporary, options.evidenceOutput);
    await context.tracing.stop();
    console.log(`wrote selection evidence for ${evidence.length} private books`);
  } catch (_) {
    await page.screenshot({ path: path.join(options.diagnostics, 'failure.png'), fullPage: true })
      .catch(() => undefined);
    await context.tracing.stop({ path: path.join(options.diagnostics, 'trace.zip') })
      .catch(() => undefined);
    fail(`metadata refresh failed at ${currentAlias}; private diagnostics were retained`);
  } finally {
    await browser.close();
  }
}

main().catch(error => {
  console.error(`metadata-refresh: ${error.message}`);
  process.exitCode = 2;
});
