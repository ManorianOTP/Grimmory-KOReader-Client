const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { test, expect } = require('@playwright/test');
const { loadRuntime } = require('./runtime');
const {
  expectedWebSearchTitles,
  normalizedText,
  seriesAuthorsDisplay
} = require('./metadata_exactness');
const {
  loginThroughUi,
  openReader,
  renderedReaderFacts,
  navigateLikeReader,
  goToPercentageLikeUser,
  ensureEofLikeUser,
  createHighlightLikeUser,
  deleteHighlightLikeUser,
  exactHighlightRow,
  resolveLoadedCfiRange,
  deleteAllHighlightsLikeUser,
  createNoteLikeUser,
  deleteAllNotesLikeUser,
  editAndDeleteNoteLikeUser,
  expectRenderedCoverLike,
  progressPercentageAtServerPrecision
} = require('./browser_helpers');

const runtime = loadRuntime();
const checkpoints = [];
const journeyOutcomes = [];
const grimmoryServerVersion = runtime.health?.data?.version || runtime.serverVersion || null;

function recordJourneyOutcomes(journey, outcomes, coverageAliases = []) {
  if (!outcomes || typeof outcomes !== 'object' || Array.isArray(outcomes) ||
      Object.keys(outcomes).length === 0 || Object.values(outcomes).some(value => value !== true)) {
    throw new Error(`${journey}: every named runtime outcome must be exactly true`);
  }
  if (journeyOutcomes.some(item => item.journey === journey)) {
    throw new Error(`${journey}: runtime outcomes were recorded more than once`);
  }
  if (!Array.isArray(coverageAliases) ||
      coverageAliases.some(alias => typeof alias !== 'string' || !alias) ||
      new Set(coverageAliases).size !== coverageAliases.length) {
    throw new Error(`${journey}: coverage aliases must be unique nonempty strings`);
  }
  journeyOutcomes.push({
    schemaVersion: 1,
    journey,
    coverageAliases: [...coverageAliases].sort(),
    outcomes
  });
}

function readPrivateResult(file, label) {
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('not an object');
    return value;
  } catch (error) {
    throw new Error(`${label} is not a readable result object: ${error.message}`);
  }
}

function loadDeviceAnnotationCheckpoint(book) {
  const root = process.env.GRIMMORY_KOREADER_OUTPUT;
  if (!root) throw new Error('koreader-to-web-consumer requires GRIMMORY_KOREADER_OUTPUT');
  const jump = readPrivateResult(
    path.join(root, `reader-jump-${book.alias}`, `${book.alias}.json`),
    `${book.alias} Jump result`
  );
  const syncHere = readPrivateResult(
    path.join(root, `reader-sync-here-${book.alias}`, `${book.alias}.json`),
    `${book.alias} Sync Here result`
  );
  if (jump.passed !== true || syncHere.passed !== true) {
    throw new Error(`${book.alias}: both isolated KOReader phases must be green`);
  }
  const fingerprint = runtime.sourceFingerprint;
  if (jump.provenance?.sourceFingerprint !== fingerprint ||
      syncHere.provenance?.sourceFingerprint !== fingerprint) {
    throw new Error(`${book.alias}: KOReader/browser source fingerprint mismatch`);
  }
  const device = jump.observations?.deviceAnnotation;
  const adopted = syncHere.observations?.deviceAnnotationAdopted;
  if (!device?.id || typeof device.cfi !== 'string' || !device.cfi.startsWith('epubcfi(') ||
      typeof device.text !== 'string' || !device.text) {
    throw new Error(`${book.alias}: KOReader device annotation checkpoint is incomplete`);
  }
  if (!adopted || String(adopted.id) !== String(device.id) ||
      adopted.cfi !== device.cfi || adopted.text !== device.text) {
    throw new Error(`${book.alias}: fresh KOReader did not adopt the exact device annotation`);
  }
  return {
    ...device,
    koreaderVersion: jump.provenance?.koreaderVersion || null,
    koreaderCommit: jump.provenance?.koreaderCommit || null
  };
}

async function liveBookAnnotations(page, bookId) {
  const result = await page.evaluate(async id => {
    const token = localStorage.getItem('accessToken_Internal');
    const response = await fetch(`/api/v1/annotations/book/${id}`, {
      headers: token ? { Authorization: `Bearer ${token}` } : {}
    });
    return { status: response.status, body: response.ok ? await response.json() : null };
  }, bookId);
  expect(result.status, 'live annotation API must be readable by the logged-in browser').toBe(200);
  if (Array.isArray(result.body)) return result.body;
  if (Array.isArray(result.body?.content)) return result.body.content;
  throw new Error('live annotation API did not return an array or paged content');
}

async function liveBookSessions(page, bookId) {
  const result = await page.evaluate(async id => {
    const token = localStorage.getItem('accessToken_Internal');
    const response = await fetch(`/api/v1/reading-sessions/book/${id}?page=0&size=100`, {
      headers: token ? { Authorization: `Bearer ${token}` } : {}
    });
    return { status: response.status, body: response.ok ? await response.json() : null };
  }, bookId);
  expect(result.status, 'live reading-session API must be readable by the logged-in browser').toBe(200);
  if (Array.isArray(result.body)) return result.body;
  if (Array.isArray(result.body?.content)) return result.body.content;
  throw new Error('live reading-session API did not return an array or paged content');
}

async function liveBookProgress(page, bookId) {
  const result = await page.evaluate(async id => {
    const token = localStorage.getItem('accessToken_Internal');
    const response = await fetch(`/api/v1/app/books/${id}/progress`, {
      headers: token ? { Authorization: `Bearer ${token}` } : {}
    });
    return { status: response.status, body: response.ok ? await response.json() : null };
  }, bookId);
  expect(result.status, 'live progress API must be readable by the logged-in browser').toBe(200);
  return result.body;
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

function serverLocalDateTimeIsValid(value) {
  if (typeof value !== 'string' || !value) return false;
  const zoned = /(?:Z|[+-]\d{2}:\d{2})$/i.test(value) ? value : `${value}Z`;
  return Number.isFinite(Date.parse(zoned));
}

function exactTextFeatures(text) {
  return {
    hasSmartQuote: /[“”‘’]/u.test(text),
    hasAsciiApostrophe: text.includes("'"),
    hasNonAscii: /[^\x00-\x7f]/u.test(text)
  };
}

function displayedLanguage(value) {
  const commonLanguageNames = { en: 'English', eng: 'English' };
  return value ? (commonLanguageNames[String(value).toLowerCase()] || String(value)) : '';
}

function displayedTableDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || '');
  if (!match) return value ? String(value) : '';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return `${match[3]}-${months[Number(match[2]) - 1]}-${match[1]}`;
}

async function browserPlainText(page, html) {
  return page.evaluate(value => {
    const node = document.createElement('div');
    node.style.cssText = 'position:fixed;left:-10000px;width:800px;white-space:normal';
    node.innerHTML = String(value ?? '');
    document.body.appendChild(node);
    const text = node.innerText;
    node.remove();
    return text;
  }, html);
}

async function authenticatedBrowserPage(browser) {
  const context = await browser.newContext({
    locale: 'en-GB',
    timezoneId: 'Etc/UTC',
    viewport: { width: 1440, height: 1000 }
  });
  const page = await context.newPage();
  await loginThroughUi(page, runtime);
  return { context, page };
}

async function enableSimilarBookRecommendationsThroughUi(page) {
  await page.getByRole('link', { name: 'Settings', exact: true }).click();
  await expect(page).toHaveURL(/\/settings(?:[?#]|$)/);
  const applicationTab = page.getByRole('tab', { name: /Application/i });
  await expect(applicationTab).toBeVisible();
  await applicationTab.click();
  await expect(applicationTab).toHaveAttribute('aria-selected', 'true');
  const setting = page.locator('.setting-item').filter({ hasText: /Similar Book Recommendation/i });
  await expect(setting, 'the real-user recommendation setting must be available').toBeVisible();
  const toggle = setting.getByRole('switch');
  await expect(toggle).toBeVisible();
  if (!(await toggle.isChecked())) {
    const saved = page.waitForResponse(response =>
      response.request().method() !== 'GET' &&
      response.url().includes('/api/') &&
      response.ok()
    );
    await toggle.click();
    await saved;
  }
  await expect(toggle).toBeChecked();
}

test.describe.configure({ mode: 'serial' });

test.afterAll(() => {
  const output = path.resolve(process.env.GRIMMORY_COMPAT_OUTPUT ||
    path.join(__dirname, '../../build/grimmory-compatibility/browser'));
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, 'web-reader-checkpoints.json'), JSON.stringify({
    schemaVersion: 2,
    serverVersion: grimmoryServerVersion,
    serverImageDigest: runtime.images?.grimmory?.repoDigests?.[0] ||
      runtime.images?.grimmory?.imageId || runtime.serverImageDigest || null,
    sourceFingerprint: runtime.sourceFingerprint || runtime.metadataCache?.manifestSha256 || null,
    checkpoints,
    outcomeContract: {
      schemaVersion: 1,
      journeys: journeyOutcomes
    }
  }, null, 2));
});

test('logs in using the same form as a real user', async ({ page }) => {
  await loginThroughUi(page, runtime);
  recordJourneyOutcomes('logs in using the same form as a real user', {
    'visible-login-submit': true,
    'authenticated-library-visible': true
  });
});

test('renders cached metadata on Dashboard cards and honest empty scrollers', async ({ page }) => {
  await loginThroughUi(page, runtime);
  await page.getByRole('link', { name: 'Dashboard', exact: true }).click();
  const dashboard = page.locator('.dashboard-container');
  await expect(dashboard).toBeVisible();
  await expect(dashboard.locator('.loading-state')).toHaveCount(0);

  // The last two default scrollers are deferred until a real user scrolls
  // them into view. Exercise that viewport path instead of forcing Angular to
  // instantiate the components.
  for (let index = 0; index < 5; index += 1) {
    await page.mouse.move(900, 800);
    await page.mouse.wheel(0, 700);
    await page.waitForTimeout(150);
  }
  const scrollers = dashboard.locator('app-dashboard-scroller');
  await expect(scrollers).toHaveCount(4);
  const expectedByTitle = new Map(runtime.readerBooks.map(book =>
    [book.expectedMetadata.title, book]
  ));
  const seenTitles = new Set();
  const fingerprintedCovers = new Set();
  let emptyScrollers = 0;
  for (let index = 0; index < await scrollers.count(); index += 1) {
    const scroller = scrollers.nth(index);
    await expect(scroller.locator('.dashboard-scroller-title')).not.toBeEmpty();
    await expect(scroller.locator('.dashboard-scroller-error')).toHaveCount(0);
    const cards = scroller.locator('.dashboard-scroller-card .book-card');
    if (await cards.count() === 0) {
      emptyScrollers += 1;
      await expect(scroller.locator('.dashboard-scroller-no-books')).toBeVisible();
      continue;
    }
    await expect(scroller.locator('.dashboard-scroller-no-books')).toHaveCount(0);
    for (let cardIndex = 0; cardIndex < await cards.count(); cardIndex += 1) {
      const card = cards.nth(cardIndex);
      const title = (await card.locator('.book-title').innerText()).trim();
      const expectedBook = expectedByTitle.get(title);
      expect(expectedBook, 'every Dashboard card must map to an imported expected book').toBeTruthy();
      seenTitles.add(title);
      await expect(card.locator('.book-title')).toHaveText(expectedBook.expectedMetadata.title);
      if (expectedBook.expectedMetadata.coverPresent) {
        await expectRenderedCoverLike(
          card.locator('app-cover img'), expectedBook.expectedMetadata,
          `Dashboard ${expectedBook.alias}`
        );
        fingerprintedCovers.add(expectedBook.alias);
        // Covered v3.3.1 cards do not render author text; author remains fully
        // asserted in the All Books table and detail surfaces below.
        await expect(card.locator('app-cover .placeholder-author')).toHaveCount(0);
      } else {
        await expect(card.locator('app-cover img')).toHaveCount(0);
        await expect(card.locator('app-cover .placeholder-title')).toHaveText(title);
        await expect(card.locator('app-cover .placeholder-author')).toHaveText(
          (expectedBook.expectedMetadata.authors || []).join(', ')
        );
      }
    }
  }
  expect(emptyScrollers, 'fresh Dashboard must honestly render its sparse empty scrollers')
    .toBeGreaterThan(0);
  expect([...seenTitles].sort()).toEqual([...expectedByTitle.keys()].sort());
  expect(fingerprintedCovers.size, 'Dashboard must visually fingerprint all eight real covers').toBe(8);
  recordJourneyOutcomes('renders cached metadata on Dashboard cards and honest empty scrollers', {
    'exact-dashboard-scroller-membership': true,
    'exact-card-metadata': true,
    'legitimate-empty-scrollers': true
  }, runtime.readerBooks.map(book => book.alias));
});

test('renders cached metadata in distinct Series, Author, and Metadata Manager views', async ({ page }) => {
  await loginThroughUi(page, runtime);
  const exactCardIndex = async (cards, selector, value) => cards.evaluateAll(
    (items, expected) => items.findIndex(item =>
      (item.querySelector(expected.selector)?.textContent || '').trim() === expected.value
    ),
    { selector, value }
  );

  const seriesGroups = new Map();
  for (const book of runtime.readerBooks) {
    const seriesName = book.expectedMetadata.series?.name;
    if (!seriesName) continue;
    if (!seriesGroups.has(seriesName)) seriesGroups.set(seriesName, []);
    seriesGroups.get(seriesName).push(book);
  }
  await page.getByRole('link', { name: 'Series', exact: true }).click();
  await expect(page.locator('.series-browser-page')).toBeVisible();
  const seriesCards = page.locator('app-series-card');
  await expect(seriesCards).toHaveCount(seriesGroups.size);
  for (const [seriesName, books] of seriesGroups) {
    const index = await exactCardIndex(seriesCards, '.series-name', seriesName);
    expect(index, `Series browser card for ${seriesName} must exist`).toBeGreaterThanOrEqual(0);
    const card = seriesCards.nth(index);
    await expect(card.locator('.series-name')).toHaveText(seriesName);
    const authors = [...new Set(books.flatMap(book => book.expectedMetadata.authors || []))];
    await expect(card.locator('.series-authors')).toHaveText(seriesAuthorsDisplay(authors));
    await expect(card.locator('.progress-label')).toHaveText(new RegExp(`^\\d+/${books.length}$`));
    await card.click();
    const seriesPage = page.locator('.series-wrapper');
    await expect(seriesPage).toBeVisible();
    await expect(seriesPage.locator('.series-title')).toHaveText(seriesName);
    expect((await seriesPage.locator('.series-authors .author-link').allInnerTexts()).map(normalizedText))
      .toEqual(authors);
    for (const publisher of [...new Set(books.map(book => book.expectedMetadata.publisher).filter(Boolean))]) {
      await expect(seriesPage.locator('.meta-card-publisher')).toContainText(publisher);
    }
    for (const language of [...new Set(books.map(book =>
      displayedLanguage(book.expectedMetadata.languageDisplay || book.expectedMetadata.languageName ||
        book.expectedMetadata.language)).filter(Boolean))]) {
      await expect(seriesPage.locator('.meta-card-language')).toContainText(language);
    }
    for (const book of books) {
      const cards = seriesPage.locator('.series-items-grid app-book-card');
      const bookIndex = await exactCardIndex(cards, '.book-title', book.expectedMetadata.title);
      expect(bookIndex, `Series detail card for ${book.alias} must exist`).toBeGreaterThanOrEqual(0);
      await expectRenderedCoverLike(
        cards.nth(bookIndex).locator('app-cover img'), book.expectedMetadata,
        `Series detail ${book.alias}`
      );
    }
    expect((await seriesPage.locator('.series-items-grid app-book-card .book-title').allInnerTexts())
      .map(normalizedText).sort()).toEqual(books.map(book => book.expectedMetadata.title).sort());
    await seriesPage.getByRole('tab', { name: /Book List/i }).click();
    const listCards = seriesPage.locator('.book-list-card');
    await expect(listCards).toHaveCount(books.length);
    for (const book of books) {
      const bookIndex = await exactCardIndex(listCards, '.list-book-title', book.expectedMetadata.title);
      expect(bookIndex, `Series list row for ${book.alias} must exist`).toBeGreaterThanOrEqual(0);
      const row = listCards.nth(bookIndex);
      await expect(row.locator('.list-book-authors')).toHaveText(
        (book.expectedMetadata.authors || []).join(', ')
      );
      if (book.expectedMetadata.pageCount !== null && book.expectedMetadata.pageCount !== undefined) {
        await expect(row.locator('.list-book-pages')).toContainText(String(book.expectedMetadata.pageCount));
      }
      await expectRenderedCoverLike(
        row.locator('app-cover img'), book.expectedMetadata, `Series list ${book.alias}`
      );
    }
    await page.getByRole('link', { name: 'Series', exact: true }).click();
    await expect(page.locator('.series-browser-page')).toBeVisible();
  }

  const authorGroups = new Map();
  for (const book of runtime.readerBooks) {
    for (const author of book.expectedMetadata.authors || []) {
      if (!authorGroups.has(author)) authorGroups.set(author, []);
      authorGroups.get(author).push(book);
    }
  }
  await page.getByRole('link', { name: 'Authors', exact: true }).click();
  await expect(page.locator('.author-browser-page')).toBeVisible();
  const authorCards = page.locator('app-author-card');
  await expect(authorCards).toHaveCount(authorGroups.size);
  for (const [author, books] of authorGroups) {
    const index = await exactCardIndex(authorCards, '.author-name', author);
    expect(index, `Author browser card for ${author} must exist`).toBeGreaterThanOrEqual(0);
    const card = authorCards.nth(index);
    await expect(card.locator('.author-name')).toHaveText(author);
    await expect(card.locator('.book-count-badge')).toHaveText(String(books.length));
    await card.click();
    const detail = page.locator('.author-wrapper');
    await expect(detail).toBeVisible();
    await expect(detail.locator('.author-title')).toHaveText(author);
    await expect(detail.locator('.section-title')).toContainText(`(${books.length})`);
    const bookCards = detail.locator('.author-books-scroller app-book-card');
    await expect(bookCards).toHaveCount(books.length);
    expect((await bookCards.locator('.book-title').allInnerTexts()).map(normalizedText).sort())
      .toEqual(books.map(book => book.expectedMetadata.title).sort());
    for (const book of books) {
      const bookIndex = await exactCardIndex(bookCards, '.book-title', book.expectedMetadata.title);
      expect(bookIndex, `Author detail card for ${book.alias} must exist`).toBeGreaterThanOrEqual(0);
      const rendered = bookCards.nth(bookIndex);
      if (book.expectedMetadata.coverPresent) {
        await expectRenderedCoverLike(
          rendered.locator('app-cover img'), book.expectedMetadata, `Author detail ${book.alias}`
        );
      } else {
        await expect(rendered.locator('app-cover img')).toHaveCount(0);
        await expect(rendered.locator('.placeholder-title')).toHaveText(book.expectedMetadata.title);
      }
    }
    await page.getByRole('link', { name: 'Authors', exact: true }).click();
    await expect(page.locator('.author-browser-page')).toBeVisible();
  }

  const managerFields = [
    ['Authors', metadata => metadata.authors || []],
    ['Genres', metadata => metadata.genres || metadata.categories || []],
    ['Moods', metadata => metadata.moods || []],
    ['Tags', metadata => metadata.tags || []],
    ['Series', metadata => metadata.series?.name ? [metadata.series.name] : []],
    ['Publishers', metadata => metadata.publisher ? [metadata.publisher] : []],
    ['Languages', metadata => metadata.language ? [metadata.language] : []]
  ];
  await page.getByRole('link', { name: 'Metadata Manager', exact: true }).click();
  const manager = page.locator('app-metadata-manager .main-container');
  await expect(manager).toBeVisible();
  for (const [tabName, valuesFor] of managerFields) {
    const counts = new Map();
    for (const book of runtime.readerBooks) {
      for (const value of valuesFor(book.expectedMetadata)) {
        counts.set(value, (counts.get(value) || 0) + 1);
      }
    }
    // PrimeNG exposes its decorative icon glyph in the accessible name on
    // v3.3.1, so anchor the meaningful label/count at the end.
    const tab = manager.getByRole('tab', { name: new RegExp(`${tabName} \\(\\d+\\)$`) });
    await expect(tab).toBeVisible();
    await tab.click();
    const panel = manager.locator('p-tabpanel:visible');
    const rows = panel.locator('tbody tr');
    await expect(rows).toHaveCount(counts.size);
    const rendered = await rows.evaluateAll(items => items.map(row => {
      const cells = row.querySelectorAll('td');
      return [(cells[1]?.textContent || '').trim(), Number((cells[2]?.textContent || '').trim())];
    }));
    expect(new Map(rendered)).toEqual(counts);
  }
  recordJourneyOutcomes('renders cached metadata in distinct Series, Author, and Metadata Manager views', {
    'exact-series-membership': true,
    'exact-author-membership': true,
    'exact-metadata-manager-values': true
  }, runtime.readerBooks.map(book => book.alias));
});

test('renders cached metadata on the library grid, table, and book detail', async ({ page }) => {
  await loginThroughUi(page, runtime);
  const fingerprintedCovers = new Set();
  if (runtime.readerBooks.some(book => (book.serverDerivedAfterReplay?.recommendations || []).length)) {
    // Recommendations are an opt-in application feature. Enabling them through
    // Settings is part of the user journey; setting the database directly would
    // conceal a broken or inaccessible preference control.
    await enableSimilarBookRecommendationsThroughUi(page);
  }

  for (const book of runtime.readerBooks) {
    await test.step(`${book.kind}: ${book.alias}`, async () => {
      const expected = book.expectedMetadata;
      // Stay inside Grimmory's client-side application and use the same
      // navigation link a user does. Full document reloads can strand lazy
      // JavaScript chunks on the pinned server and are not the normal journey.
      await page.getByRole('link', { name: /All Books/i }).click();
      await expect(page.locator('.book-browser-container')).toBeVisible();
      // Exercise the actual view toggle. A bare `view=table` query parameter is
      // deliberately ignored by Grimmory unless it was produced by that user
      // control, so forcing the URL would not represent real behaviour.
      if (await page.locator('app-book-table').count()) {
        await page.locator('a.toolbar-item').filter({ has: page.locator('i.pi-table') }).click();
        await expect(page.locator('app-book-table')).toHaveCount(0);
      }
      const libraryCards = page.locator('.book-card');
      const gridCardIndex = await libraryCards.evaluateAll((cards, title) => cards.findIndex(item =>
        (item.querySelector('.book-title')?.textContent || '').trim() === title
      ), expected.title);
      expect(gridCardIndex, `grid card for ${book.alias} must be exact`).toBeGreaterThanOrEqual(0);
      const card = libraryCards.nth(gridCardIndex);
      await expect(card).toBeVisible();
      await expect(card.locator('.book-title')).toHaveText(expected.title);
      if (expected.coverPresent) {
        await expectRenderedCoverLike(card.locator('app-cover img'), expected, `All Books grid ${book.alias}`);
      } else {
        await expect(card.locator('app-cover img')).toHaveCount(0);
        await expect(card.locator('app-cover .placeholder-title')).toHaveText(expected.title);
        await expect(card.locator('app-cover .placeholder-author')).toHaveText(
          (expected.authors || []).join(', ')
        );
      }

      const searchInput = page.locator('.desktop-search-wrapper input.search-input');
      await expect(searchInput).toBeVisible();
      await searchInput.fill(expected.title);
      const expectedSearchTitles = expectedWebSearchTitles(runtime.readerBooks, expected.title);
      await expect.poll(async () => (await page.locator('.book-card .book-title').allInnerTexts())
        .map(normalizedText).sort(), {
        message: `${book.alias}: visible search result set must be exact`
      }).toEqual(expectedSearchTitles);
      await searchInput.fill('');
      await expect.poll(async () => page.locator('.book-card').count())
        .toBe(runtime.readerBooks.length);

      await page.locator('a.toolbar-item').filter({ has: page.locator('i.pi-objects-column') }).click();
      await expect(page.locator('app-book-table')).toBeVisible();
      const headers = await page.locator('.book-table-header-cell').allInnerTexts();
      const titleColumnIndex = headers.findIndex(header => header.trim() === 'Title');
      expect(titleColumnIndex, 'the Title table column must be rendered').toBeGreaterThanOrEqual(0);
      const tableRows = page.locator('app-book-table-row');
      await expect(tableRows.first()).toBeVisible();
      const tableRowIndex = await tableRows.evaluateAll((rows, expectedTitle) => rows.findIndex(row =>
        (row.querySelectorAll('.book-table-cell')[expectedTitle.columnIndex]?.textContent || '').trim() === expectedTitle.title
      ), { title: expected.title, columnIndex: titleColumnIndex });
      expect(tableRowIndex, `table row for ${book.alias} must exist`).toBeGreaterThanOrEqual(0);
      const tableRow = tableRows.nth(tableRowIndex);
      await expect(tableRow).toBeVisible();
      await expect(tableRow.locator('.cover-link')).toHaveAttribute('aria-label', expected.title);
      if (expected.coverPresent) {
        await expectRenderedCoverLike(tableRow.locator('app-cover img'), expected, `All Books table ${book.alias}`);
      } else {
        await expect(tableRow.locator('app-cover img')).toHaveCount(0);
        await expect(tableRow.locator('app-cover .placeholder-title')).toHaveText(expected.title);
      }
      const tableCell = label => {
        const index = headers.findIndex(header => header.trim() === label);
        expect(index, `the ${label} table column must be rendered`).toBeGreaterThanOrEqual(0);
        return tableRow.locator('.book-table-cell').nth(index);
      };
      const tableValues = {
        Title: expected.title,
        Authors: (expected.authors || []).join(', '),
        Publisher: expected.publisher || '',
        Series: expected.series?.name || '',
        'Series #': expected.series?.number ?? '',
        Published: displayedTableDate(expected.publishedDate),
        Language: displayedLanguage(expected.languageDisplay || expected.languageName || expected.language),
        ISBN: expected.identifiers?.isbn13 || expected.identifiers?.isbn10 || '',
        Pages: expected.pageCount ?? '',
        'AZ #': expected.ratings?.amazonReviewCount ?? '',
        'GR #': expected.ratings?.goodreadsReviewCount ?? '',
        'HC #': expected.ratings?.hardcoverReviewCount ?? ''
      };
      for (const [label, value] of Object.entries(tableValues)) {
        await expect(tableCell(label)).toHaveText(String(value));
      }
      const expectedGenres = expected.genres || expected.categories || [];
      const renderedGenres = (await tableCell('Genres').innerText())
        .split(',').map(value => value.trim()).filter(Boolean);
      expect(renderedGenres.sort()).toEqual([...expectedGenres].sort());
      for (const [label, rating] of [
        ['Amazon', expected.ratings?.amazon],
        ['Goodreads', expected.ratings?.goodreads],
        ['Hardcover', expected.ratings?.hardcover]
      ]) {
        const ratingCell = tableCell(label);
        if (rating === null || rating === undefined) {
          await expect(ratingCell.getByLabel('No rating')).toBeVisible();
        } else {
          await expect(ratingCell.getByLabel(`${Number(rating).toFixed(1)} out of 5`)).toBeVisible();
        }
      }

      await tableCell('Title').locator('a.cell-link').click();
      const details = page.locator('.metadata-viewer-container');
      await expect(details).toBeVisible();
      // Subtitle is rendered inline after `: `. Exact text proves both its
      // presence and its deliberate absence instead of only checking positives.
      const expectedDetailTitle = expected.subtitle
        ? `${expected.title}: ${expected.subtitle}` : expected.title;
      await expect(details.locator('h1.book-title')).toHaveText(expectedDetailTitle);

      const metadataValue = async label => {
        const escaped = String(label).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const rowPattern = new RegExp(`^${escaped}:\\s*(.*)$`);
        const matches = (await details.locator('.metadata-item').allInnerTexts())
          .map(normalizedText)
          .map(text => rowPattern.exec(text))
          .filter(Boolean);
        expect(matches, `${label} must identify exactly one complete metadata row`).toHaveLength(1);
        return matches[0][1];
      };
      for (const [field, label] of [['publisher', 'Publisher'], ['publishedDate', 'Published']]) {
        const value = expected[field];
        expect(await metadataValue(label)).toBe(
          value === null || value === undefined || value === '' ? '-' : String(value)
        );
      }
      const language = expected.languageDisplay || expected.languageName || expected.language;
      expect(await metadataValue('Language')).toBe(
        language === null || language === undefined || language === ''
          ? '-' : displayedLanguage(language)
      );
      const series = expected.series;
      if (series && typeof series === 'object') {
        if (series.name) {
          await expect(details.locator('.series-link')).toHaveText(
            series.number ? `${series.name} #${series.number}` : series.name
          );
        } else {
          await expect(details.locator('.series-link')).toHaveCount(0);
        }
      } else if (series) {
        await expect(details.locator('.series-link')).toHaveText(String(series));
      } else {
        await expect(details.locator('.series-link')).toHaveCount(0);
      }
      if (expected.description) {
        const expectedDescription = normalizedText(await browserPlainText(page, expected.description));
        const renderedDescription = normalizedText(await details.locator('.description-html').innerText());
        expect(renderedDescription).toBe(expectedDescription);
      } else {
        await expect(details.locator('.description-html')).toBeEmpty();
      }
      expect((await details.locator('.authors .author-link').allInnerTexts()).map(normalizedText))
        .toEqual(expected.authors || []);
      const genres = expected.genres || expected.categories || [];
      const expectedTagRows = [[genres, 'Genres'], [expected.moods || [], 'Moods'],
        [expected.tags || [], 'Tags']]
        .filter(([values]) => values.length)
        .map(([values, label]) => ({ label: `${label}:`, values: [...values].sort() }));
      const renderedTagRows = (await details.locator('.tags-section .tag-row').evaluateAll(rows =>
        rows.map(row => ({
          label: row.querySelector('.tag-label')?.textContent || '',
          values: [...row.querySelectorAll('.tag-clickable')].map(item => item.textContent || '')
        }))))
        .map(row => ({
          label: normalizedText(row.label),
          values: row.values.map(normalizedText)
        }));
      for (const row of renderedTagRows) {
        expect(new Set(row.values).size, `${row.label} must not render duplicate metadata chips`)
          .toBe(row.values.length);
        row.values.sort();
      }
      expect(renderedTagRows).toEqual(expectedTagRows);
      if (expected.pageCount === null || expected.pageCount === undefined) {
        expect(await metadataValue('Page Count')).toBe('-');
      } else {
        expect(await metadataValue('Page Count')).toBe(String(expected.pageCount));
      }
      const isbnValues = [expected.identifiers?.isbn13, expected.identifiers?.isbn10].filter(Boolean);
      expect(await metadataValue('ISBN')).toBe(
        isbnValues.length ? isbnValues.join(' / ') : '-'
      );

      const derived = book.serverDerivedAfterReplay;
      expect(derived, `${book.alias} must distinguish server-derived values from provider cache`).toBeTruthy();
      expect(derived.source).toEqual({
        kind: 'grimmory-local-api-after-replay',
        endpoints: {
          recommendations: `/api/v1/books/${book.serverBookId}/recommendations`,
          personalRating: `/api/v1/books/${book.serverBookId}?withDescription=true`,
          metadataMatchScore: `/api/v1/books/${book.serverBookId}?withDescription=true`
        },
        providerNetworkUsed: false
      });
      if (derived.metadataMatchScore === null || derived.metadataMatchScore === undefined) {
        expect(await metadataValue('Metadata Match')).toBe('-');
      } else {
        expect(await metadataValue('Metadata Match')).toBe(
          `${Math.round(derived.metadataMatchScore)}%`
        );
      }
      const personalRating = details.locator('.personal-rating p-rating');
      await expect(personalRating).toBeVisible();
      if (derived.personalRating === null || derived.personalRating === undefined) {
        await expect(personalRating.locator('.p-rating-option-active')).toHaveCount(0);
      } else {
        await expect(personalRating.locator('.p-rating-option-active')).toHaveCount(
          Math.round(Number(derived.personalRating))
        );
      }

      const ratings = expected.ratings || {};
      const ratingDomains = {
        amazon: 'amazon.', goodreads: 'goodreads.com', hardcover: 'hardcover.app',
        audible: 'audible.com', google: 'books.google.com'
      };
      for (const [provider, domain] of Object.entries(ratingDomains)) {
        const rating = ratings[provider];
        const identifierKeys = {
          amazon: 'Amazon', goodreads: 'GoodReads', hardcover: 'Hardcover',
          audible: 'Audible', google: 'Google'
        };
        const identifier = expected.identifiers?.[identifierKeys[provider]];
        const locator = details.locator(`.rating-link[href*="${domain}"]`);
        if (rating === null || rating === undefined ? !identifier : false) {
          await expect(locator).toHaveCount(0);
          continue;
        }
        await expect(locator).toBeVisible();
        if (identifier) await expect(locator).toHaveAttribute('href', new RegExp(String(identifier)));
        if (typeof rating === 'number') {
          await expect(locator.locator('.rating-value')).toContainText(`${Math.round(rating * 20)}%`);
          const reviewCount = ratings[`${provider}ReviewCount`];
          if (reviewCount !== null && reviewCount !== undefined) {
            await locator.hover();
            await expect(page.locator('.p-tooltip-text')).toContainText(Number(reviewCount).toLocaleString('en-GB'));
          }
        }
      }

      if (expected.coverPresent === false) {
        await expect(details.locator('app-cover img[src*="/api/v1/media/book/"]')).toHaveCount(0);
      }
      if (expected.coverVisualFingerprint) {
        const coverImage = details.locator('.cover-section app-cover img').first();
        await expectRenderedCoverLike(coverImage, expected, `book detail ${book.alias}`);
        fingerprintedCovers.add(book.alias);
      }

      const reviews = [...(expected.reviews || [])].sort((left, right) => {
        if (!left.date && !right.date) return 0;
        if (!left.date) return 1;
        if (!right.date) return -1;
        return new Date(right.date).getTime() - new Date(left.date).getTime();
      });
      const reviewsTab = details.getByRole('tab', { name: /Reviews/i });
      // Reviews is unconditional in pinned v3.3.1. A missing tab is a product
      // regression, even when the provider correctly returned no review bodies.
      await expect(reviewsTab).toBeVisible();
      await reviewsTab.click();
      await expect(details.locator('app-book-reviews .book-reviews-container')).toBeVisible();
      await expect(details.locator('app-book-reviews .loading-state')).toHaveCount(0);
      const reviewCards = details.locator('.review-card');
      await expect(reviewCards).toHaveCount(reviews.length);
      for (let reviewIndex = 0; reviewIndex < reviews.length; reviewIndex += 1) {
        const review = reviews[reviewIndex];
        const reviewCard = reviewCards.nth(reviewIndex);
        await expect(reviewCard.locator('.reviewer-name')).toHaveText(review.reviewerName || 'Anonymous');
        const expectedTags = [review.metadataProvider, review.country, review.spoiler ? 'Spoiler' : null]
          .filter(Boolean);
        expect((await reviewCard.locator('.p-tag-label').allInnerTexts()).map(normalizedText))
          .toEqual(expectedTags);
        if (review.rating) await expect(reviewCard.locator('.rating-text')).toHaveText(`${review.rating}/5`);
        else await expect(reviewCard.locator('.rating-text')).toHaveCount(0);
        if (review.date) {
          const formatted = new Date(review.date).toLocaleDateString('en-US', {
            year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC'
          });
          await expect(reviewCard.locator('.review-meta-text')).toHaveText(formatted);
        } else {
          await expect(reviewCard.locator('.review-meta-text')).toHaveCount(0);
        }
        if (review.spoiler) {
          await expect(reviewCard).toHaveClass(/has-spoiler/);
          if (review.title) await expect(reviewCard.locator('.review-title--blurred')).toHaveText(review.title);
          if (review.body) await expect(reviewCard.locator('.review-body--blurred')).toHaveText(review.body);
          await reviewCard.locator('.spoiler-overlay-button').click();
          if (review.title) {
            await expect(reviewCard.locator('.review-title-section .review-title')).toHaveText(review.title);
          }
          if (review.body) {
            await expect(reviewCard.locator('.review-body:not(.review-body--blurred)')).toHaveText(review.body);
          }
        } else if (review.body) {
          if (review.title) await expect(reviewCard.locator('.review-title')).toHaveText(review.title);
          await expect(reviewCard.locator('.review-body')).toHaveText(review.body);
        }
      }

      const recommendations = derived.recommendations || [];
      const similarTab = details.getByRole('tab', { name: /Similar Books/i });
      if (recommendations.length) {
        const displayedRecommendations = recommendations
          .map((recommendation, sourceIndex) => ({ recommendation, sourceIndex }))
          .sort((left, right) =>
            (Number(right.recommendation.similarityScore) || 0) -
              (Number(left.recommendation.similarityScore) || 0) ||
            left.sourceIndex - right.sourceIndex)
          .map(item => item.recommendation);
        await expect(similarTab).toBeVisible();
        await similarTab.click();
        const similarPanel = details.getByRole('tabpanel', { name: /Similar Books/i });
        await expect(similarPanel).toBeVisible();
        const recommendationCards = similarPanel.locator('app-book-card-lite-component');
        await expect(recommendationCards).toHaveCount(displayedRecommendations.length);
        for (let recommendationIndex = 0; recommendationIndex < displayedRecommendations.length;
          recommendationIndex += 1) {
          const recommendation = displayedRecommendations[recommendationIndex];
          const recommendationTitle = recommendation.title || recommendation;
          const recommendedBook = runtime.readerBooks.find(candidate =>
            candidate.expectedMetadata.title === recommendationTitle
          );
          expect(recommendedBook, `recommendation ${recommendationTitle} must identify an imported book`)
            .toBeTruthy();
          expect(recommendation.authors || []).toEqual(recommendedBook.expectedMetadata.authors || []);
          expect(recommendation.seriesName ?? null)
            .toBe(recommendedBook.expectedMetadata.series?.name ?? null);
          const recommendationCard = recommendationCards.nth(recommendationIndex);
          if (recommendedBook.expectedMetadata.coverPresent) {
            const recommendationCover = recommendationCard.getByAltText(recommendationTitle, { exact: true });
            await expectRenderedCoverLike(
              recommendationCover, recommendedBook.expectedMetadata,
              `Similar Books ${recommendedBook.alias}`
            );
          } else {
            const placeholder = recommendationCard.locator('app-cover');
            await expect(placeholder.locator('.placeholder-title')).toHaveText(recommendationTitle);
            await expect(placeholder.locator('.placeholder-author')).toHaveText(
              (recommendedBook.expectedMetadata.authors || []).join(', ')
            );
          }
        }
      } else {
        if (await similarTab.count()) {
          await similarTab.click();
          await expect(details.locator('.dashboard-scroller-card')).toHaveCount(0);
        } else {
          await expect(similarTab).toHaveCount(0);
        }
      }
    });
  }
  expect(fingerprintedCovers.size, 'grid/table/detail must visually fingerprint all eight real covers').toBe(8);
  recordJourneyOutcomes('renders cached metadata on the library grid, table, and book detail', {
    'exact-grid-identity': true,
    'exact-table-metadata': true,
    'exact-detail-metadata': true,
    'exact-search-result-set': true,
    'offline-provider-provenance': true
  }, runtime.readerBooks.map(book => book.alias));
});

test('proves exact visible Go target containment for synthetic and private EPUBs', async ({ browser }) => {
  for (const book of runtime.readerBooks) {
    await test.step(`${book.kind}: ${book.alias}`, async () => {
      const { context, page } = await authenticatedBrowserPage(browser);
      try {
        const observer = await openReader(page, runtime, book);
        const progress = await goToPercentageLikeUser(page, observer, book,
          currentPercentage => currentPercentage >= 70 ? 40 : 80);
        checkpoints.push({
          journey: 'web-reader-go-target-containment',
          kind: book.kind,
          alias: book.alias,
          serverBookId: book.serverBookId,
          progress: {
            percentage: progress.epubProgress.percentage,
            cfi: progress.epubProgress.cfi,
            href: progress.epubProgress.href || null
          },
          goTargetContainment: progress.goTargetContainment
        });
        observer.dispose();
      } finally {
        await context.close();
      }
    });
  }
  recordJourneyOutcomes('proves exact visible Go target containment for synthetic and private EPUBs', {
    'visible-go-action': true,
    'resolver-anchor-in-page-snap-cell': true,
    'exact-post-get-progress': true
  }, runtime.readerBooks.map(book => book.alias));
});

test('opens, reads, and saves real document progress for synthetic and private EPUBs', async ({ browser }) => {
  for (const book of runtime.readerBooks) {
    await test.step(`${book.kind}: ${book.alias}`, async () => {
      const { context, page: readerPage } = await authenticatedBrowserPage(browser);
      try {
        const observer = await openReader(readerPage, runtime, book);
        const facts = await renderedReaderFacts(readerPage);
        expect(facts.contentDocuments).toBeGreaterThan(0);
        expect(facts.documentMarkupCharacters).toBeGreaterThan(20);
        const progress = await navigateLikeReader(readerPage, observer, book);
        checkpoints.push({
          journey: 'web-reader-progress',
          kind: book.kind,
          alias: book.alias,
          serverBookId: book.serverBookId,
          percentage: progress.epubProgress.percentage,
          cfi: progress.epubProgress.cfi,
          href: progress.epubProgress.href || null,
          bookFileId: progress.fileProgress?.bookFileId || null
        });
        observer.dispose();
      } finally {
        await context.close();
      }
    });
  }
  recordJourneyOutcomes('opens, reads, and saves real document progress for synthetic and private EPUBs', {
    'visible-reader-movement': true,
    'distinct-document-cfi': true,
    'exact-persisted-progress': true
  }, runtime.readerBooks.map(book => book.alias));
});

test('creates and deletes highlights through the rendered web reader', async ({ browser }) => {
  for (const book of runtime.readerBooks) {
    await test.step(`${book.kind}: ${book.alias}`, async () => {
      const { context, page: readerPage } = await authenticatedBrowserPage(browser);
      try {
        const observer = await openReader(readerPage, runtime, book);
        // Reproduce the producer's hardest state explicitly: a resumed reader
        // at EOF still has styled DOM nodes, but their translated columns are
        // offscreen. The selection helper must visibly navigate back to prose.
        const eofSetup = await ensureEofLikeUser(readerPage, observer, book);
        const annotation = await createHighlightLikeUser(readerPage);
        expect(Number(annotation.bookId)).toBe(book.serverBookId);
        await deleteHighlightLikeUser(readerPage, annotation);
        checkpoints.push({
          journey: 'web-reader-highlight-create-delete',
          kind: book.kind,
          alias: book.alias,
          serverBookId: book.serverBookId,
          annotationId: annotation.id,
          cfi: annotation.cfi,
          selectedCharacters: annotation.text.length,
          selectionMethod: annotation.selectionMethod,
          selectionRecovery: annotation.selectionRecovery,
          eofPreparation: eofSetup.eofPreparation,
          eofSetup
        });
        observer.dispose();
      } finally {
        await context.close();
      }
    });
  }
  recordJourneyOutcomes('creates and deletes highlights through the rendered web reader', {
    'physical-selection': true,
    'exact-resolved-range-text': true,
    'persisted-highlight': true,
    'post-delete-absence': true
  }, runtime.readerBooks.map(book => book.alias));
});

test('creates, edits, and deletes notes through the rendered web reader', async ({ browser }) => {
  for (const book of runtime.readerBooks) {
    await test.step(`${book.kind}: ${book.alias}`, async () => {
      const { context, page: readerPage } = await authenticatedBrowserPage(browser);
      try {
        const observer = await openReader(readerPage, runtime, book);
        // A red retry may have saved a note before failing a later assertion.
        // Clear it through the same visible Notes sidebar a user owns.
        await deleteAllNotesLikeUser(readerPage);
        const noteText = `Browser note ${book.alias}`;
        const updatedText = `${noteText} updated`;
        const note = await createNoteLikeUser(readerPage, noteText);
        expect(Number(note.bookId)).toBe(book.serverBookId);
        // Close with the rendered reader control and inspect the same note on
        // Grimmory's distinct Notebook screen before returning to edit it.
        observer.dispose();
        await readerPage.mouse.move(720, 1);
        const closeReader = readerPage.locator('.reader-header button.close-btn');
        await expect(closeReader).toBeVisible();
        await closeReader.click();
        await expect(readerPage.locator('.metadata-viewer-container')).toBeVisible();
        await readerPage.getByRole('link', { name: 'Notebook', exact: true }).click();
        const notebookGroup = readerPage.locator('.book-group-card')
          .filter({ hasText: book.expectedMetadata.title });
        await expect(notebookGroup).toBeVisible();
        await expect(notebookGroup.locator('.book-title')).toHaveText(book.expectedMetadata.title);
        await expect(notebookGroup.locator('.entry-note')).toContainText(noteText);
        if (book.expectedMetadata.coverPresent) {
          await expectRenderedCoverLike(
            notebookGroup.locator('app-cover img'), book.expectedMetadata, `Notebook ${book.alias}`
          );
        } else {
          await expect(notebookGroup.locator('app-cover img')).toHaveCount(0);
          await expect(notebookGroup.locator('.placeholder-title')).toHaveText(book.expectedMetadata.title);
        }
        const reopenedObserver = await openReader(readerPage, runtime, book);
        await editAndDeleteNoteLikeUser(readerPage, note, updatedText);
        reopenedObserver.dispose();
        checkpoints.push({
          journey: 'web-reader-note-create-edit-delete',
          kind: book.kind,
          alias: book.alias,
          serverBookId: book.serverBookId,
          noteId: note.id,
          cfi: note.cfi,
          selectionMethod: note.selectionMethod,
          selectionRecovery: note.selectionRecovery
        });
      } finally {
        await context.close();
      }
    });
  }
  recordJourneyOutcomes('creates, edits, and deletes notes through the rendered web reader', {
    'physical-selection': true,
    'exact-resolved-note-range': true,
    'persisted-note-edit': true,
    'post-delete-absence': true
  }, runtime.readerBooks.map(book => book.alias));
});

test('records a real user reading session for synthetic and private EPUBs', async ({ browser }) => {
  // Session creation intentionally uses real elapsed time. Browser clock
  // injection would prove our test doubles, not Grimmory's user lifecycle.
  for (const book of runtime.readerBooks) {
    await test.step(`${book.kind}: ${book.alias}`, async () => {
      const { context, page } = await authenticatedBrowserPage(browser);
      try {
      const baseline = await liveBookSessions(page, book.serverBookId);
      const baselineIds = new Set(baseline.map(item => String(item.id)));
      const sessionResponse = page.waitForResponse(response =>
        response.request().method() === 'POST' && response.url().endsWith('/api/v1/reading-sessions'),
        { timeout: 60 * 1000 }
      );
      const openingActionNotBefore = Date.now();
      const observer = await openReader(page, runtime, book);
      // Pinned Grimmory starts a reading session from the first valid Foliate
      // relocation, before any later Go action. Capture that exact successful
      // opening POST and its persisted server representation independently.
      await expect.poll(() => observer.progressPosts[0]?.epubProgress?.cfi || null, {
        message: 'reader opening must persist the relocation that starts the session'
      }).not.toBeNull();
      const openingProgressPost = {
        ...observer.progressPosts[0].epubProgress
      };
      await expect.poll(() => observer.progressResponses.find(item =>
        item.ok && item.body?.epubProgress?.cfi === openingProgressPost.cfi &&
        Number(item.body?.epubProgress?.percentage) === Number(openingProgressPost.percentage)
      ) || null, {
        message: 'the exact opening relocation that starts the session must persist successfully'
      }).not.toBeNull();
      const openingProgressObservedNotAfter = Date.now();
      const openingLive = await liveBookProgress(page, book.serverBookId);
      const openingPersistedProgress = { ...openingLive.epubProgress };
      expect(openingPersistedProgress.cfi).toBe(openingProgressPost.cfi);
      expect(openingPersistedProgress.href ?? null).toBe(openingProgressPost.href ?? null);
      expect(Number(openingPersistedProgress.percentage)).toBe(
        progressPercentageAtServerPrecision(openingProgressPost.percentage));
      // A retry may reopen a book already at its final page. Use the visible
      // location control to prove genuine movement after the independently
      // captured opening session start.
      const goProgressPost = await goToPercentageLikeUser(page, observer, book,
        currentPercentage => currentPercentage >= 70 ? 40 : 80);
      expect(goProgressPost.epubProgress.cfi).not.toBe(openingProgressPost.cfi);
      expect(Number(goProgressPost.epubProgress.percentage)).not.toBe(
        Number(openingProgressPost.percentage));
      // Keep the minimum-duration interval stationary. A flood of asynchronous
      // key presses can relocate again after an apparent final response and
      // creates a stale end oracle. After real elapsed time, make exactly one
      // visible section navigation whose helper owns its exact POST and GET.
      const stationaryProgressPosts = observer.progressPosts.length;
      const stationaryStartedAt = Date.now();
      await page.waitForTimeout(31_000);
      const stationaryEndedAt = Date.now();
      expect(stationaryEndedAt - stationaryStartedAt).toBeGreaterThanOrEqual(31_000);
      expect(observer.progressPosts).toHaveLength(stationaryProgressPosts);
      const stationaryProgressPostsAfter = observer.progressPosts.length;
      const endNavigation = await navigateLikeReader(page, observer, book);
      const endProgressPost = {
        ...endNavigation.epubProgress
      };
      const endLive = await liveBookProgress(page, book.serverBookId);
      const endPersistedProgress = { ...endLive.epubProgress };
      expect(endPersistedProgress.cfi).toBe(endProgressPost.cfi);
      expect(endPersistedProgress.href ?? null).toBe(endProgressPost.href ?? null);
      expect(Number(endPersistedProgress.percentage)).toBe(
        progressPercentageAtServerPrecision(endProgressPost.percentage));
      await page.mouse.move(720, 1);
      const closeReader = page.locator('.reader-header button.close-btn');
      await expect(closeReader).toBeVisible();
      const closedNotBefore = Date.now();
      await closeReader.click();
      const response = await sessionResponse;
      const closedNotAfter = Date.now();
      expect(response.ok()).toBeTruthy();
      const posted = response.request().postDataJSON();
      const postedStart = Date.parse(posted.startTime);
      const postedEnd = Date.parse(posted.endTime);
      expect(Number.isFinite(postedStart)).toBeTruthy();
      expect(Number.isFinite(postedEnd)).toBeTruthy();
      expect(new Date(postedStart).toISOString()).toBe(posted.startTime);
      expect(new Date(postedEnd).toISOString()).toBe(posted.endTime);
      expect(postedStart).toBeGreaterThanOrEqual(openingActionNotBefore);
      expect(postedStart).toBeLessThanOrEqual(openingProgressObservedNotAfter);
      expect(postedEnd).toBeGreaterThanOrEqual(closedNotBefore);
      expect(postedEnd).toBeLessThanOrEqual(closedNotAfter);
      const expectedDurationSeconds = Math.floor((postedEnd - postedStart) / 1000);
      expect(expectedDurationSeconds).toBeGreaterThanOrEqual(
        Math.floor((closedNotBefore - openingProgressObservedNotAfter) / 1000));
      expect(expectedDurationSeconds).toBeLessThanOrEqual(
        Math.ceil((closedNotAfter - openingActionNotBefore) / 1000));
      expect(expectedDurationSeconds).toBeGreaterThanOrEqual(30);
      const expectedPosted = {
        bookId: book.serverBookId,
        bookType: 'EPUB',
        startTime: posted.startTime,
        endTime: posted.endTime,
        durationSeconds: expectedDurationSeconds,
        durationFormatted: formattedReadingSessionDuration(expectedDurationSeconds),
        startProgress: roundedReadingSessionProgress(openingProgressPost.percentage),
        endProgress: roundedReadingSessionProgress(endProgressPost.percentage),
        progressDelta: roundedReadingSessionProgress(
          roundedReadingSessionProgress(endProgressPost.percentage) -
            Number(openingProgressPost.percentage)),
        startLocation: openingProgressPost.cfi,
        endLocation: endProgressPost.cfi
      };
      expect(Object.keys(posted).sort()).toEqual(Object.keys(expectedPosted).sort());
      expect(posted).toEqual(expectedPosted);

      await expect.poll(async () => (await liveBookSessions(page, book.serverBookId))
        .filter(item => !baselineIds.has(String(item.id))).length, {
          message: 'the server must list exactly one session created by this reader lifecycle'
        }).toBe(1);
      const after = await liveBookSessions(page, book.serverBookId);
      const created = after.filter(item => !baselineIds.has(String(item.id)));
      expect(created).toHaveLength(1);
      expect(created[0].id).not.toBeNull();
      expect(baselineIds.has(String(created[0].id))).toBeFalsy();
      expect(serverLocalDateTimeIsValid(created[0].createdAt)).toBeTruthy();
      const expectedListed = {
        id: created[0].id,
        bookId: book.serverBookId,
        bookTitle: book.expectedMetadata.title,
        bookType: 'EPUB',
        startTime: persistedReadingSessionTimestamp(posted.startTime),
        endTime: persistedReadingSessionTimestamp(posted.endTime),
        durationSeconds: expectedDurationSeconds,
        startProgress: expectedPosted.startProgress,
        endProgress: expectedPosted.endProgress,
        progressDelta: expectedPosted.progressDelta,
        startLocation: openingProgressPost.cfi,
        endLocation: endProgressPost.cfi,
        createdAt: created[0].createdAt
      };
      expect(Object.keys(created[0]).sort()).toEqual(Object.keys(expectedListed).sort());
      expect(created[0]).toEqual(expectedListed);
      checkpoints.push({
        journey: 'web-reader-reading-session',
        kind: book.kind,
        alias: book.alias,
        serverBookId: book.serverBookId,
        sessionId: created[0].id,
        baselineSessionIds: [...baselineIds],
        openingProgressPost,
        openingPersistedProgress,
        goProgressPost: { ...goProgressPost.epubProgress },
        stationaryEvidence: {
          durationMs: stationaryEndedAt - stationaryStartedAt,
          progressPostCountBefore: stationaryProgressPosts,
          progressPostCountAfter: stationaryProgressPostsAfter
        },
        endNavigationControl: endNavigation.navigationControl,
        endProgressPost,
        endPersistedProgress,
        lifecycleBounds: {
          openingActionNotBefore,
          openingProgressObservedNotAfter,
          closedNotBefore,
          closedNotAfter
        },
        postedSession: posted,
        listedSession: created[0],
        goTargetContainment: goProgressPost.goTargetContainment
      });
      observer.dispose();
      } finally {
        await context.close();
      }
    });
  }
  recordJourneyOutcomes('records a real user reading session for synthetic and private EPUBs', {
    'exact-opening-persisted-session-start': true,
    'exact-opening-response-time-bound': true,
    'visible-go-movement-after-session-start': true,
    'exact-complete-posted-session-dto': true,
    'exact-complete-listed-session-dto': true,
    'exact-datetime-zero-post-to-list-normalization': true,
    'stationary-real-duration-before-single-end-navigation': true,
    'exact-visible-persisted-end-navigation': true
  }, runtime.readerBooks.map(book => book.alias));
});

// Keep the cross-device producer as the final mutating browser journey. Its
// progress and annotation state must remain untouched until the isolated
// KOReader consumer has verified and adopted it.
test('web-to-koreader-producer leaves web-origin checkpoints for the isolated KOReader consumer', async ({ browser }) => {
  for (const book of runtime.readerBooks) {
    await test.step(`${book.kind}: ${book.alias}`, async () => {
      const { context, page } = await authenticatedBrowserPage(browser);
      try {
        const observer = await openReader(page, runtime, book);
        // The disposable producer may be retried after a red run. Clear only
        // this test profile's server highlights through the visible sidebar so
        // a retry cannot leave an unowned annotation behind.
        await deleteAllHighlightsLikeUser(page);
        // Keep the exact v2 regression in the producer itself. A user who last
        // stopped at EOF must still be able to create a physical selection;
        // only visible-range coordinates are eligible after this navigation.
        const eofSetup = await ensureEofLikeUser(page, observer, book);
        const annotation = await createHighlightLikeUser(page);
        const progress = await goToPercentageLikeUser(page, observer, book,
          currentPercentage => currentPercentage >= 70 ? 60 : 85);
        expect(progress.epubProgress.cfi).toMatch(/^epubcfi\(/);
        expect(progress.epubProgress.percentage).toBeGreaterThan(50);
        checkpoints.push({
          journey: 'web-to-koreader-producer',
          kind: book.kind,
          alias: book.alias,
          serverBookId: book.serverBookId,
          sourceSha256: book.sourceSha256,
          progress: {
            percentage: progress.epubProgress.percentage,
            cfi: progress.epubProgress.cfi,
            href: progress.epubProgress.href || null,
            bookFileId: progress.fileProgress?.bookFileId || null,
            goTargetContainment: progress.goTargetContainment
          },
          eofPreparation: eofSetup.eofPreparation,
          eofSetup,
          annotation: {
            id: annotation.id,
            cfi: annotation.cfi,
            text: annotation.text,
            color: annotation.color,
            style: annotation.style,
            note: annotation.note || null,
            selectionMethod: annotation.selectionMethod,
            selectionRecovery: annotation.selectionRecovery
          },
          cleanupOwner: 'koreader-full-server-consumer'
        });
        observer.dispose();
      } finally {
        await context.close();
      }
    });
  }
  recordJourneyOutcomes('web-to-koreader-producer leaves web-origin checkpoints for the isolated KOReader consumer', {
    'physical-selection': true,
    'exact-foliate-range': true,
    'producer-state-emitted-for-independent-live-readback': true
  }, runtime.readerBooks.map(book => book.alias));
});

test('koreader-to-web-consumer resolves the complete device-origin range before visible cleanup', async ({ browser }) => {
  for (const book of runtime.readerBooks) {
    await test.step(`${book.kind}: ${book.alias}`, async () => {
      const device = loadDeviceAnnotationCheckpoint(book);
      const { context, page } = await authenticatedBrowserPage(browser);
      try {
        const observer = await openReader(page, runtime, book);

        const annotations = await liveBookAnnotations(page, book.serverBookId);
        expect(annotations, `${book.alias}: browser consumer requires one unambiguous server annotation`)
          .toHaveLength(1);
        const server = annotations[0];
        expect(String(server.id)).toBe(String(device.id));
        expect(server.cfi).toBe(device.cfi);
        expect(server.text).toBe(device.text);

        // Navigate exactly as a user does: open the visible Highlights panel
        // and click the full-text row. Only then ask Foliate's independently
        // pinned CFI resolver for the DOM Range loaded by that navigation.
        await page.mouse.move(720, 1);
        await page.locator('.reader-header button[title="Chapters"]').click();
        await page.locator('.sidebar .tabs .tab').filter({ hasText: 'Highlights' }).click();
        const row = await exactHighlightRow(page, server.text);
        await row.locator('.item-content').click();
        await expect(page.locator('.sidebar')).toHaveCount(0);

        const resolved = await resolveLoadedCfiRange(page, server.cfi);
        expect(resolved.collapsed, `${book.alias}: device CFI must resolve to a non-collapsed range`)
          .toBe(false);
        expect(resolved.text, `${book.alias}: Foliate DOM Range must equal the entire KOReader selection`)
          .toBe(device.text);
        expect(resolved.text, `${book.alias}: Foliate DOM Range must equal the entire server annotation`)
          .toBe(server.text);

        const features = exactTextFeatures(device.text);
        const utf8Bytes = Buffer.byteLength(device.text, 'utf8');
        expect(features.hasSmartQuote,
          `${book.alias}: selected regression text must exercise smart punctuation`).toBe(true);
        expect(features.hasNonAscii,
          `${book.alias}: smart-punctuation selection must retain non-ASCII input`).toBe(true);
        expect(utf8Bytes, `${book.alias}: selection must be at least five UTF-8 bytes`)
          .toBeGreaterThanOrEqual(5);
        expect(utf8Bytes, `${book.alias}: selection must be at most 500 UTF-8 bytes`)
          .toBeLessThanOrEqual(500);
        expect(/[\u0000-\u001f\u007f]/u.test(device.text),
          `${book.alias}: exact selection must not contain control separators`).toBe(false);
        expect(device.selection?.crossesInlineBoundary,
          `${book.alias}: KOReader must deliberately select across an inline-element boundary`).toBe(true);
        expect(device.selection?.sameRenderedBlock,
          `${book.alias}: KOReader selection must stay in one exact leaf block`).toBe(true);
        expect(device.selection?.startBlockPath).toBe(device.selection?.endBlockPath);
        expect(device.selection?.startInlinePath,
          `${book.alias}: KOReader endpoints must have different inline ancestry`)
          .not.toBe(device.selection?.endInlinePath);
        expect(resolved.endpointsAreTextNodes,
          `${book.alias}: Foliate range endpoints must both be Text nodes`).toBe(true);
        expect(resolved.crossesInlineElementBoundary,
          `${book.alias}: Foliate must resolve the same inline-element boundary`).toBe(true);
        expect(resolved.sameLeafBlock,
          `${book.alias}: Foliate range endpoints must share one leaf-block object`).toBe(true);
        expect(resolved.acceptsSameLeafBlockInlineRange,
          `${book.alias}: Foliate must accept the strict same-block inline range`).toBe(true);
        expect(resolved.startLeafBlockPath).toBe(resolved.endLeafBlockPath);

        // The browser becomes cleanup owner only after all three exact strings
        // have compared equal. Deletion is another visible user action.
        await page.mouse.move(720, 1);
        await page.locator('.reader-header button[title="Chapters"]').click();
        await page.locator('.sidebar .tabs .tab').filter({ hasText: 'Highlights' }).click();
        const cleanupRow = await exactHighlightRow(page, server.text);
        const deleted = page.waitForResponse(response =>
          response.request().method() === 'DELETE' &&
          response.url().includes(`/api/v1/annotations/${server.id}`)
        );
        await cleanupRow.locator('.delete-btn').click();
        expect((await deleted).ok()).toBeTruthy();
        await expect(page.locator('.sidebar .highlight-item')).toHaveCount(0);
        expect(await liveBookAnnotations(page, book.serverBookId),
          `${book.alias}: visible browser cleanup must leave the server empty`).toHaveLength(0);

        const textSha256 = crypto.createHash('sha256').update(device.text, 'utf8').digest('hex');
        checkpoints.push({
          journey: 'koreader-to-web-consumer',
          checkpointContract: 'device-to-web-exact-range/v2',
          coverageSet: 'synthetic-plus-eight-real-epubs',
          kind: book.kind,
          alias: book.alias,
          serverBookId: book.serverBookId,
          sourceSha256: book.sourceSha256,
          sourceFingerprint: runtime.sourceFingerprint,
          producer: {
            engine: 'KOReader-CREngine',
            version: device.koreaderVersion,
            commit: device.koreaderCommit,
            realSaveHighlightAction: true,
            productionUploadHook: true,
            freshReaderExactAdoption: true,
            selection: device.selection
          },
          consumer: {
            engine: 'Grimmory-Foliate',
            serverVersion: grimmoryServerVersion,
            navigationMethod: 'visible-highlights-row-click',
            resolutionOracle: 'foliate-resolveNavigation-anchor-dom-range-toString',
            exactKoreaderServerDomText: true,
            nonCollapsedRange: true,
            crossesDomNodeBoundary: resolved.crossesDomNodeBoundary,
            crossesInlineElementBoundary: resolved.crossesInlineElementBoundary,
            endpointsAreTextNodes: resolved.endpointsAreTextNodes,
            sameLeafBlock: resolved.sameLeafBlock,
            acceptsSameLeafBlockInlineRange: resolved.acceptsSameLeafBlockInlineRange,
            startLeafBlockPath: resolved.startLeafBlockPath,
            endLeafBlockPath: resolved.endLeafBlockPath,
            startInlineAncestryPaths: resolved.startInlineAncestryPaths,
            endInlineAncestryPaths: resolved.endInlineAncestryPaths,
            visibleCleanupAfterResolution: true,
            serverEmptyAfterCleanup: true
          },
          selectedText: {
            sha256: textSha256,
            utf8Bytes,
            utf16CodeUnits: device.text.length,
            hasControlSeparators: false,
            ...features
          },
          invariants: {
            device_selection_uploaded_via_production_hooks: true,
            fresh_koreader_adopted_exact_device_annotation: true,
            live_server_text_equals_complete_koreader_selection: true,
            visible_sidebar_row_has_exact_whole_text_identity: true,
            foliate_device_cfi_resolves_noncollapsed_dom_range: true,
            foliate_dom_range_text_equals_complete_koreader_selection: true,
            foliate_dom_range_text_equals_live_server_text: true,
            inline_boundary_requirement_enforced_for_all_epubs: true,
            same_leaf_block_requirement_enforced_for_all_epubs: true,
            control_separator_free_selection: true,
            cleanup_occurs_only_after_three_way_text_equality: true,
            server_empty_after_visible_cleanup: true
          }
        });
        observer.dispose();
      } finally {
        await context.close();
      }
    });
  }
  recordJourneyOutcomes(
    'koreader-to-web-consumer resolves the complete device-origin range before visible cleanup',
    {
      'genuine-koreader-highlight-uploaded-through-production-hooks': true,
      'fresh-koreader-adopted-exact-device-annotation': true,
      'live-server-text-equals-complete-koreader-selection': true,
      'visible-sidebar-row-has-exact-whole-text-identity': true,
      'device-cfi-resolves-to-noncollapsed-foliate-dom-range': true,
      'foliate-range-text-equals-complete-koreader-and-server-text': true,
      'all-epub-selection-crosses-inline-element-boundary': true,
      'all-epub-selection-stays-in-one-leaf-block': true,
      'selection-has-no-control-separators': true,
      'cleanup-occurs-only-after-three-way-text-equality': true,
      'server-empty-after-visible-browser-cleanup': true,
      'synthetic-plus-eight-real-epubs-covered-exactly-once': true
    },
    runtime.readerBooks.map(book => book.alias)
  );
});

test('documents pinned v3.3.1 upstream capability boundaries', async () => {
  // In pinned Grimmory v3.3.1, the rendered reader calls annotation POST and
  // DELETE. `updateAnnotationNote()` exists in its service but is not wired to
  // any component. Highlight edit conflicts therefore originate from KOReader
  // in the full-server suite; this assertion prevents us from falsely claiming
  // a web UI journey. Promote this test when Grimmory adds that user control.
  //
  // The same release's BookPatchService uses distinctUntilChanged followed by
  // exhaustMap for progress POSTs. A relocation made while a slow save is in
  // flight can therefore be discarded upstream. Normal acceptance deliberately
  // waits for the first save response before one visible Next Section click,
  // but that pacing is not evidence that rapid input is lossless. This remains
  // a documented, non-blocking upstream risk until a pinned upgrade changes it.
  expect(grimmoryServerVersion).toMatch(/^v?3\.3\.1(?:[-+].*)?$/);
  recordJourneyOutcomes('documents pinned v3.3.1 upstream capability boundaries', {
    'pinned-server-release-3.3.1-confirmed': true
  });
});
