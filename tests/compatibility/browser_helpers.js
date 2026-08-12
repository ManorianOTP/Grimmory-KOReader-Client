const { expect } = require('@playwright/test');
const { spawnSync } = require('node:child_process');

async function loginThroughUi(page, runtime) {
  await page.goto(`${runtime.baseUrl}/login`);
  await page.locator('#username').fill(runtime.username);
  await page.locator('p-password input[type="password"]').fill(runtime.password);
  await Promise.all([
    page.waitForURL(url => !url.pathname.endsWith('/login')),
    page.locator('button[type="submit"]').click()
  ]);
  await expect(page.locator('app-layout, app-sidebar, .layout-wrapper').first()).toBeVisible();
}

async function openReader(page, runtime, book) {
  const progressPosts = [];
  const progressResponses = [];
  const isThisBookProgressRequest = request => {
    if (request.method() !== 'POST' || !request.url().includes('/api/v1/books/progress')) return false;
    try {
      return Number(request.postDataJSON()?.bookId) === book.serverBookId;
    } catch (_) {
      return false;
    }
  };
  const listener = async request => {
    if (!isThisBookProgressRequest(request)) return;
    try {
      progressPosts.push(request.postDataJSON());
    } catch (_) {
      // A malformed progress request will fail the behavioural assertions below.
    }
  };
  const responseListener = response => {
    const request = response.request();
    if (!isThisBookProgressRequest(request)) return;
    progressResponses.push({
      body: request.postDataJSON(),
      ok: response.ok(),
      status: response.status()
    });
  };
  page.on('request', listener);
  page.on('response', responseListener);
  await page.getByRole('link', { name: /All Books/i }).click();
  await expect(page.locator('.book-browser-container')).toBeVisible();
  if (await page.locator('app-book-table').count()) {
    await page.locator('a.toolbar-item').filter({ has: page.locator('i.pi-table') }).click();
    await expect(page.locator('app-book-table')).toHaveCount(0);
  }
  const cards = page.locator('.book-card');
  await expect(cards.first()).toBeVisible();
  const cardIndex = await cards.evaluateAll((items, title) => items.findIndex(item =>
    (item.querySelector('.book-title')?.textContent || '').trim() === title
  ), book.expectedMetadata.title);
  expect(cardIndex, `All Books card for ${book.alias} must exist`).toBeGreaterThanOrEqual(0);
  const card = cards.nth(cardIndex);
  await card.scrollIntoViewIfNeeded();
  // Grimmory reveals the View details control only while the user is hovering
  // the cover. Exercise that interaction rather than forcing a hidden button.
  await card.hover();
  const detailsButton = card.getByRole('button', { name: 'View book details' });
  await expect(detailsButton).toBeVisible();
  await detailsButton.click();
  const details = page.locator('.metadata-viewer-container');
  await expect(details).toBeVisible();
  await expect(details.locator('h1.book-title')).toContainText(book.expectedMetadata.title);
  const readButton = details.locator('.action-buttons-container .primary-actions button').first();
  await expect(readButton, `book detail for ${book.alias} must expose Read`).toBeVisible();
  await readButton.click();
  await expect(page).toHaveURL(new RegExp(`/ebook-reader/book/${book.serverBookId}(?:[?#]|$)`));
  await expect(page.locator('#foliate-container foliate-view')).toBeVisible();
  await expect.poll(async () => page.locator('foliate-view').evaluate(view =>
    Number(view?.renderer?.getContents?.()?.length || 0)
  )).toBeGreaterThan(0);
  // The reader header is a distinct metadata renderer. Reveal it with the
  // same top-edge hover a user employs and prove it identifies this book.
  await page.mouse.move(720, 1);
  await expect(page.locator('.reader-header .chapter-title')).toHaveText(
    book.expectedMetadata.title
  );
  await page.mouse.move(720, 500);
  return {
    progressPosts,
    progressResponses,
    dispose: () => {
      page.off('request', listener);
      page.off('response', responseListener);
    }
  };
}

async function renderedReaderFacts(page) {
  return page.locator('foliate-view').evaluate(view => {
    const contents = view?.renderer?.getContents?.() || [];
    const text = contents.map(item => item.doc?.body?.innerText || '').join('\n').trim();
    return {
      contentDocuments: contents.length,
      visibleCharacters: text.length,
      visibleImages: contents.reduce((count, item) =>
        count + (item.doc?.querySelectorAll?.('img,svg,image,object,video')?.length || 0), 0),
      documentMarkupCharacters: contents.reduce((count, item) =>
        count + (item.doc?.documentElement?.outerHTML?.length || 0), 0)
    };
  });
}

function isDistinctProgress(previous, current) {
  return !!previous && !!current &&
    current.epubProgress?.cfi !== previous.epubProgress?.cfi &&
    Number(current.epubProgress?.percentage) !== Number(previous.epubProgress?.percentage);
}

function progressPercentageAtServerPrecision(value) {
  return Number(Number(value).toPrecision(6));
}

function persistedProgressIsAtTarget(payload, targetPercentage) {
  return progressPercentageAtServerPrecision(payload?.epubProgress?.percentage) ===
    progressPercentageAtServerPrecision(targetPercentage);
}

async function visibleReaderLocation(page) {
  await page.mouse.move(720, 999);
  const location = page.locator('.reader-navbar .location-text');
  await expect(location).toBeVisible();
  const percentage = Number.parseFloat((await location.innerText()).replace('%', ''));
  const visibleContent = await page.locator('foliate-view').evaluate(view => {
    const snippets = [];
    const media = [];
    for (const { doc } of view?.renderer?.getContents?.() || []) {
      const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode()) && snippets.length < 30) {
        const text = node.nodeValue || '';
        for (const match of text.matchAll(/\S+/g)) {
          const range = doc.createRange();
          range.setStart(node, match.index);
          range.setEnd(node, match.index + match[0].length);
          const rects = [...range.getClientRects()];
          if (rects.some(rect => rect.width > 0 && rect.height > 0 &&
            rect.right > 0 && rect.bottom > 0 &&
            rect.left < doc.defaultView.innerWidth && rect.top < doc.defaultView.innerHeight)) {
            snippets.push(match[0]);
            if (snippets.length >= 30) break;
          }
        }
      }
      for (const element of doc.querySelectorAll('img,svg,image,object,video')) {
        const rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0 || rect.right <= 0 || rect.bottom <= 0 ||
            rect.left >= doc.defaultView.innerWidth || rect.top >= doc.defaultView.innerHeight) continue;
        media.push([
          element.tagName,
          element.getAttribute('src') || element.getAttribute('data') ||
            element.getAttribute('href') || element.getAttribute('xlink:href') || '',
          element.getAttribute('alt') || '',
          Math.round(rect.left), Math.round(rect.top), Math.round(rect.width), Math.round(rect.height)
        ].join(':'));
      }
    }
    return {
      text: snippets.join(' ').slice(0, 1000),
      media: media.sort().join('|').slice(0, 4000)
    };
  });
  return { percentage, visibleContent };
}

function readerLocationChanged(previous, current) {
  return current.percentage !== previous.percentage ||
    current.visibleContent.text !== previous.visibleContent.text ||
    current.visibleContent.media !== previous.visibleContent.media;
}

function deriveGoTargetContainment(targetFraction, state) {
  const numericState = [
    ['target fraction', targetFraction],
    ['resolved section', state.resolvedSection],
    ['visible section', state.visibleSection],
    ['resolved anchor', state.resolvedAnchor],
    ['renderer page', state.rendererPage],
    ['renderer pages', state.rendererPages],
    ['last location fraction', state.lastFraction]
  ];
  for (const [label, value] of numericState) {
    if (!Number.isFinite(value)) throw new TypeError(`${label} must be a finite number`);
  }
  if (!Array.isArray(state.sectionFractions)) {
    throw new TypeError('section fractions must be an array');
  }
  if (!Number.isInteger(state.visibleSection) || state.visibleSection < 0 ||
      state.visibleSection + 1 >= state.sectionFractions.length) {
    throw new RangeError('visible section must identify a bounded section interval');
  }
  const textPages = state.rendererPages - 2;
  const contentPage = state.rendererPage - 1;
  if (!Number.isInteger(textPages) || textPages <= 0) {
    throw new RangeError('renderer must expose at least one text page');
  }
  if (!Number.isInteger(contentPage) || contentPage < 0 || contentPage >= textPages) {
    throw new RangeError('renderer content page must lie inside its text page count');
  }
  const expectedPage = Math.round(state.resolvedAnchor * (textPages - 1));
  const sectionStart = state.sectionFractions[state.visibleSection];
  const sectionEnd = state.sectionFractions[state.visibleSection + 1];
  if (!Number.isFinite(sectionStart) || !Number.isFinite(sectionEnd) || sectionEnd <= sectionStart) {
    throw new RangeError('visible section fractions must form a finite increasing interval');
  }
  const sectionWeight = sectionEnd - sectionStart;
  const pageStart = sectionStart + contentPage / textPages * sectionWeight;
  const pageEnd = pageStart + sectionWeight / textPages;
  const anchorDivisor = textPages - 1;
  const anchorStart = anchorDivisor === 0 || contentPage === 0
    ? 0 : (contentPage - 0.5) / anchorDivisor;
  const anchorEnd = anchorDivisor === 0 || contentPage === textPages - 1
    ? 1 : (contentPage + 0.5) / anchorDivisor;
  const anchorEndInclusive = contentPage === textPages - 1;
  const anchorContained = state.resolvedAnchor >= anchorStart &&
    (anchorEndInclusive ? state.resolvedAnchor <= anchorEnd : state.resolvedAnchor < anchorEnd);
  const targetContained = state.resolvedSection === state.visibleSection &&
    contentPage === expectedPage && anchorContained;
  return {
    targetFraction,
    resolvedSection: state.resolvedSection,
    visibleSection: state.visibleSection,
    resolvedAnchor: state.resolvedAnchor,
    textPages,
    contentPage,
    expectedPage,
    sectionStart,
    sectionEnd,
    sectionWeight,
    pageStart,
    pageEnd,
    anchorStart,
    anchorEnd,
    anchorEndInclusive,
    anchorContained,
    targetContained,
    reportedPageContainsRequestedFraction:
      targetFraction >= pageStart && targetFraction <= pageEnd,
    reportedPageContainsLastFraction:
      state.lastFraction >= pageStart && state.lastFraction <= pageEnd,
    lastFraction: state.lastFraction,
    lastCfi: state.lastCfi,
    scrolled: state.scrolled
  };
}

async function assertGoTargetContainment(page, requestedPercentage, progress) {
  const targetFraction = Number(requestedPercentage) / 100;
  const state = await page.locator('foliate-view').evaluate((view, target) => {
    const resolved = view.resolveNavigation({ fraction: target });
    const renderer = view.renderer;
    const visible = renderer.getContents()[0];
    return {
      resolvedSection: resolved.index,
      resolvedAnchor: resolved.anchor,
      visibleSection: visible.index,
      rendererPage: renderer.page,
      rendererPages: renderer.pages,
      scrolled: renderer.scrolled,
      sectionFractions: view.getSectionFractions().map(value => value - Number.EPSILON),
      lastFraction: view.lastLocation.fraction,
      lastCfi: view.lastLocation.cfi
    };
  }, targetFraction);
  const proof = deriveGoTargetContainment(targetFraction, state);
  expect(proof.scrolled, 'Go target containment requires the paginated reader mode').toBeFalsy();
  expect(proof.textPages, 'Foliate must expose at least one rendered text page').toBeGreaterThan(0);
  expect(proof.visibleSection, 'visible section must equal Foliate resolved target section')
    .toBe(proof.resolvedSection);
  expect(proof.contentPage, 'visible content page must equal Foliate resolved target page')
    .toBe(proof.expectedPage);
  // Foliate chooses the nearest content page with round(anchor *
  // (textPages - 1)). Its relocation progress divides the section into
  // textPages equal intervals, so the requested global fraction is not
  // guaranteed to lie in that later reported interval. Prove the exact inverse
  // rounding cell instead; this uses no tolerance or guessed threshold.
  expect(proof.anchorContained,
    `resolved anchor must lie inside the rendered page rounding cell: ${JSON.stringify(proof)}`)
    .toBeTruthy();
  expect(proof.targetContained,
    'Foliate must resolve the requested target onto the exact visible rendered page').toBeTruthy();
  expect(progress.epubProgress.cfi, 'progress POST must use Foliate lastLocation CFI')
    .toBe(proof.lastCfi);
  expect(Number(progress.epubProgress.percentage), 'progress POST must use Foliate lastLocation fraction')
    .toBe(proof.lastFraction * 100);
  const visible = await visibleReaderLocation(page);
  expect(visible.percentage, 'visible rounded percentage must represent the posted rendered page')
    .toBe(Math.round(Number(progress.epubProgress.percentage)));
  return {
    requestedPercentage: Number(requestedPercentage),
    ...proof,
    postedPercentage: Number(progress.epubProgress.percentage),
    visibleRoundedPercentage: visible.percentage
  };
}

async function visibleSectionControl(page, title) {
  await page.mouse.move(720, 999);
  // The location popover repeats Previous/Next Section controls. Scope this to
  // the persistent footer so an open popover can never make the physical
  // control ambiguous.
  const control = page.locator(`.reader-navbar > button.icon-btn[title="${title}"]`);
  await expect(control, `Grimmory must expose its visible ${title} control`).toBeVisible();
  const viewport = page.viewportSize();
  expect(viewport, 'browser viewport is required to validate click bounds').toBeTruthy();
  // The animated footer can extend a few CSS pixels below the viewport. Its
  // accessible control must intersect the real viewport; locator.click retains
  // Playwright's full hit-target/actionability checks.
  await expect.poll(async () => {
    const candidate = await control.boundingBox();
    return Boolean(candidate && candidate.x < viewport.width &&
      candidate.y < viewport.height && candidate.x + candidate.width > 0 &&
      candidate.y + candidate.height > 0);
  }, {
    message: `${title} animated footer control must enter the real viewport`,
    timeout: 3_000
  }).toBe(true);
  // Do not immediately resample the animated geometry: that creates a TOCTOU
  // race in which the successful intersection frame can move by one CSS pixel
  // before a redundant assertion. The next locator.click still performs
  // Playwright's live actionability and hit-target checks.
  return control;
}

async function clickSectionControlLikeUser(page, title) {
  const before = await visibleReaderLocation(page);
  const control = await visibleSectionControl(page, title);
  await expect(control, `${title} must be enabled before physical navigation`).toBeEnabled();
  await control.click();
  await expect.poll(async () => readerLocationChanged(before, await visibleReaderLocation(page)), {
    message: `one physical click on ${title} must visibly move the rendered book`
  }).toBeTruthy();
  const after = await visibleReaderLocation(page);
  return { before, after };
}

async function settleObservedProgress(observer) {
  const { progressPosts, progressResponses } = observer;
  await expect.poll(() => progressPosts.length,
    { message: 'reader must establish initial persisted progress before another user action' }
  ).toBeGreaterThan(0);
  await expect.poll(() => progressResponses.length,
    { message: 'initial progress POST must finish before the next physical action' }
  ).toBeGreaterThanOrEqual(progressPosts.length);
  expect(progressResponses.at(-1).ok, 'initial progress POST must succeed').toBeTruthy();
}

async function readLiveProgress(page, book) {
  return page.evaluate(async bookId => {
    const token = localStorage.getItem('accessToken_Internal');
    const response = await fetch(`/api/v1/app/books/${bookId}/progress`, {
      headers: token ? { Authorization: `Bearer ${token}` } : {}
    });
    return { status: response.status, body: response.ok ? await response.json() : null };
  }, book.serverBookId);
}

async function assertLiveProgressMatches(page, book, payload) {
  expect(payload.epubProgress?.cfi, 'web reader must post a document-derived CFI').toMatch(/^epubcfi\(/);
  expect(payload.epubProgress?.percentage, 'web reader must post percentage points').toBeGreaterThanOrEqual(0);
  expect(payload.epubProgress?.percentage).toBeLessThanOrEqual(100);
  const live = await readLiveProgress(page, book);
  expect(live.status, 'read-only live progress GET must succeed').toBe(200);
  expect(live.body.epubProgress?.cfi).toBe(payload.epubProgress.cfi);
  // Pinned v3.3.1 persists this through MariaDB FLOAT and a Java Float/JDBC
  // round trip, observed across both sub-1% and whole-percent values as six
  // significant decimal digits. Compare that exact persisted representation,
  // not a loose numerical tolerance.
  const postedPercentageAtServerPrecision = progressPercentageAtServerPrecision(
    payload.epubProgress.percentage
  );
  expect(Number(live.body.epubProgress?.percentage)).toBe(postedPercentageAtServerPrecision);
  expect(live.body.epubProgress?.href ?? null).toBe(payload.epubProgress.href ?? null);
  return live.body;
}

async function performPersistedProgressAction(page, observer, book, action, message) {
  await settleObservedProgress(observer);
  const { progressPosts, progressResponses } = observer;
  const baseline = progressPosts.at(-1);
  const before = progressPosts.length;
  const visibleBefore = await visibleReaderLocation(page);
  await action();
  await expect.poll(async () => {
    return readerLocationChanged(visibleBefore, await visibleReaderLocation(page));
  }, { message: `${message} must visibly move the rendered book` }).toBeTruthy();

  await expect.poll(() => progressPosts.slice(before).find(payload =>
    isDistinctProgress(baseline, payload)
  ) || null, {
    message: `${message} must produce a later POST with distinct CFI and percentage`
  }).toBeTruthy();
  const payload = progressPosts.slice(before).find(candidate => isDistinctProgress(baseline, candidate));
  await expect.poll(() => progressResponses.find(response =>
    response.ok && response.body.epubProgress?.cfi === payload.epubProgress.cfi &&
    Number(response.body.epubProgress?.percentage) === Number(payload.epubProgress.percentage)
  ) || null, { message: 'the exact distinct progress POST must complete successfully' }).toBeTruthy();
  await assertLiveProgressMatches(page, book, payload);
  return payload;
}

async function navigateLikeReader(page, observer, book) {
  let navigationControl;
  const progress = await performPersistedProgressAction(page, observer, book, async () => {
    const next = await visibleSectionControl(page, 'Next Section');
    const previous = await visibleSectionControl(page, 'Previous Section');
    const nextEnabled = await next.isEnabled();
    const previousEnabled = await previous.isEnabled();
    expect(nextEnabled || previousEnabled,
      'at least one visible section control must be enabled before physical navigation').toBeTruthy();
    navigationControl = nextEnabled ? 'Next Section' : 'Previous Section';
    await (nextEnabled ? next : previous).click();
  }, 'one physical click on an enabled visible section control');
  progress.navigationControl = navigationControl;
  return progress;
}

async function goToPercentageLikeUser(page, observer, book, percentage) {
  let requestedPercentage;
  const progress = await performPersistedProgressAction(page, observer, book, async () => {
    await page.mouse.move(720, 999);
    await page.locator('.reader-navbar .location-btn').click();
    const input = page.locator('#reader-go-to-percentage');
    await expect(input).toBeVisible();
    requestedPercentage = typeof percentage === 'function'
      ? percentage(Number(await input.inputValue())) : percentage;
    await input.fill(String(requestedPercentage));
    await page.locator('.location-popover .go-btn').click();
  }, 'visible Go to percentage action');
  // Grimmory v3.3.1 deliberately leaves this popover open after Go. Close it
  // through the same visible percentage button so later footer navigation has
  // one unambiguous set of Previous/Next controls.
  const popover = page.locator('.location-popover');
  await expect(popover, 'Go to percentage must leave its visible popover open').toBeVisible();
  await page.locator('.reader-navbar .location-btn').click();
  await expect(popover, 'the user must visibly close the location popover').toHaveCount(0);
  progress.goTargetContainment = await assertGoTargetContainment(
    page, requestedPercentage, progress
  );
  return progress;
}

async function ensureEofLikeUser(page, observer, book) {
  const target = 100;
  await settleObservedProgress(observer);
  const visible = await visibleReaderLocation(page);
  const initialProgress = observer.progressPosts.at(-1);
  const initialLive = await readLiveProgress(page, book);
  const slider = page.locator('.reader-navbar').getByRole('slider', { name: 'Progress' });
  const next = await visibleSectionControl(page, 'Next Section');
  const sliderValue = await slider.inputValue();
  const nextSectionDisabled = await next.isDisabled();
  const initialLiveMatches = initialLive.status === 200 &&
    initialLive.body?.epubProgress?.cfi === initialProgress.epubProgress?.cfi &&
    (initialLive.body?.epubProgress?.href ?? null) === (initialProgress.epubProgress?.href ?? null) &&
    Number(initialLive.body?.epubProgress?.percentage) === target;
  const alreadyAtExactPersistedEof = visible.percentage === target &&
    sliderValue === String(target) && nextSectionDisabled &&
    persistedProgressIsAtTarget(initialProgress, target) && initialLiveMatches;

  let progress = initialProgress;
  let eofPreparation = 'already-at-exact-persisted-eof';
  if (!alreadyAtExactPersistedEof) {
    progress = await goToPercentageLikeUser(page, observer, book, target);
    eofPreparation = 'moved-to-exact-persisted-eof';
  }

  await expect(page.locator('.reader-navbar .location-text')).toHaveText('100%');
  await expect(slider, 'the visible footer progress slider must be at exact EOF').toBeVisible();
  await expect(slider).toHaveValue('100');
  const finalNext = await visibleSectionControl(page, 'Next Section');
  await expect(finalNext, 'exact EOF must disable the footer Next Section control').toBeDisabled();
  expect(
    persistedProgressIsAtTarget(progress, target),
    'the reader progress POST must persist exact EOF'
  ).toBeTruthy();
  const live = await assertLiveProgressMatches(page, book, progress);
  expect(Number(live.epubProgress?.percentage), 'live persisted EOF must be exactly 100').toBe(100);
  return {
    eofPreparation,
    visiblePercentage: 100,
    sliderValue: Number(await slider.inputValue()),
    nextSectionDisabled: await finalNext.isDisabled(),
    persistedPercentage: Number(live.epubProgress.percentage),
    persistedCfi: live.epubProgress.cfi,
    persistedHref: live.epubProgress.href ?? null,
    goTargetContainment: progress.goTargetContainment || null
  };
}

async function selectionDragPoints(page, minimumCharacters = 24) {
  return page.locator('foliate-view').evaluate((view, minChars) => {
    const contents = view?.renderer?.getContents?.() || [];
    for (const { doc } of contents) {
      const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
          const value = (node.nodeValue || '').replace(/\s+/g, ' ').trim();
          const parent = node.parentElement;
          if (value.length < minChars || !parent) return NodeFilter.FILTER_REJECT;
          const style = doc.defaultView.getComputedStyle(parent);
          if (style.visibility === 'hidden' || style.display === 'none') return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      let node;
      while ((node = walker.nextNode())) {
        const raw = node.nodeValue || '';
        const startOffset = raw.search(/\S/);
        const endOffset = Math.min(raw.length, startOffset + Math.max(minChars, 40));
        const startRange = doc.createRange();
        startRange.setStart(node, startOffset);
        startRange.setEnd(node, Math.min(endOffset, startOffset + 1));
        const endRange = doc.createRange();
        endRange.setStart(node, Math.max(startOffset + 1, endOffset - 1));
        endRange.setEnd(node, endOffset);
        const startRect = startRange.getBoundingClientRect();
        const endRect = endRange.getBoundingClientRect();
        const iframe = doc.defaultView.frameElement;
        const iframeRect = iframe?.getBoundingClientRect?.();
        const viewRect = view.getBoundingClientRect();
        const docWidth = doc.defaultView.innerWidth;
        const docHeight = doc.defaultView.innerHeight;
        const rectVisible = rect => rect.width > 0 && rect.height > 0 &&
          rect.left >= 0 && rect.right <= docWidth && rect.top >= 0 && rect.bottom <= docHeight;
        if (!iframeRect || !rectVisible(startRect) || !rectVisible(endRect)) continue;
        const start = {
          x: iframeRect.left + startRect.left + Math.min(2, startRect.width / 2),
          y: iframeRect.top + startRect.top + startRect.height / 2
        };
        const end = {
          x: iframeRect.left + endRect.right - Math.min(2, endRect.width / 2),
          y: iframeRect.top + endRect.top + endRect.height / 2
        };
        const pointVisible = point => Number.isFinite(point.x) && Number.isFinite(point.y) &&
          point.x >= Math.max(0, viewRect.left, iframeRect.left) &&
          point.x <= Math.min(window.innerWidth, viewRect.right, iframeRect.right) &&
          point.y >= Math.max(0, viewRect.top, iframeRect.top) &&
          point.y <= Math.min(window.innerHeight, viewRect.bottom, iframeRect.bottom);
        if (!pointVisible(start) || !pointVisible(end)) continue;
        return { start, end, text: raw.slice(startOffset, endOffset).trim() };
      }
    }
    throw new Error('rendered EPUB has no visible selectable prose of the required length');
  }, minimumCharacters);
}

async function assertVisibleDragPoints(page, points) {
  const box = await page.locator('foliate-view').boundingBox();
  if (!box) throw new Error('Foliate view has no visible box for physical selection');
  for (const [label, point] of Object.entries({ start: points.start, end: points.end })) {
    if (!Number.isFinite(point.x) || !Number.isFinite(point.y) ||
        point.x < box.x || point.x > box.x + box.width ||
        point.y < box.y || point.y > box.y + box.height ||
        point.x < 0 || point.x > page.viewportSize().width ||
        point.y < 0 || point.y > page.viewportSize().height) {
      throw new Error(`physical drag ${label} point is outside the visible Foliate viewport`);
    }
  }
}

async function selectRenderedTextLikeUser(page) {
  let points;
  const recovery = {
    previousSectionClicks: 0,
    startPercentage: null,
    endPercentage: null,
    renderedLocationChanged: false
  };
  try {
    points = await selectionDragPoints(page);
  } catch (error) {
    if (!String(error).includes('no visible selectable prose')) throw error;
  }
  if (!points) {
    // Reopening a previously-read book can resume at 100%, where every styled
    // DOM node still exists but all earlier columns are translated offscreen.
    // Walk backward using Grimmory's visible Previous Section control. This
    // also avoids reopening the location popover while its Go action is still
    // completing its close animation.
    const recoveryStart = await visibleReaderLocation(page);
    recovery.startPercentage = recoveryStart.percentage;
    for (let attempt = 0; !points && attempt < 6; attempt += 1) {
      const previous = await visibleSectionControl(page, 'Previous Section');
      if (!(await previous.isEnabled())) break;
      const movement = await clickSectionControlLikeUser(page, 'Previous Section');
      recovery.previousSectionClicks += 1;
      recovery.endPercentage = movement.after.percentage;
      recovery.renderedLocationChanged = true;
      try {
        points = await selectionDragPoints(page);
      } catch (error) {
        if (!String(error).includes('no visible selectable prose')) throw error;
      }
    }
  }
  // A reader normally turns through a cover and front matter before opening
  // the table of contents. This also avoids depending on a deeply nested TOC
  // tree when ordinary visible navigation reaches prose directly.
  for (let attempt = 0; !points && attempt < 20; attempt += 1) {
    await page.keyboard.press('PageDown');
    await page.waitForTimeout(300);
    try {
      points = await selectionDragPoints(page);
    } catch (error) {
      if (!String(error).includes('no visible selectable prose')) throw error;
    }
  }
  if (!points) {
    // If bounded page turns cannot find prose, use the reader's visible table
    // of contents instead of mutating Foliate's location object.
    await page.mouse.move(720, 1);
    const chaptersButton = page.locator('.reader-header button[title="Chapters"]');
    await expect(chaptersButton).toBeVisible();
    await chaptersButton.click();
    const contentsTab = page.locator('.sidebar .tabs .tab').filter({ hasText: 'Contents' });
    await contentsTab.click();
    await expect(contentsTab).toHaveClass(/active/);
    for (let depth = 0; depth < 5 && await page.locator('.sidebar').count(); depth += 1) {
      const chapterRows = page.locator('.sidebar .chapter-row');
      await expect(chapterRows.first()).toBeVisible();
      const items = await chapterRows.evaluateAll(rows => rows.map(row => ({
        label: (row.querySelector('.chapter-label')?.textContent || '').replace(/\s+/g, ' ').trim(),
        expandable: row.classList.contains('expandable'),
        active: row.classList.contains('active')
      })));
      // The sidebar keeps its shell for a short closing animation after a leaf
      // is chosen, while its chapter rows are already gone.
      if (!items.length) break;
      let chapterIndex = items.findIndex(item =>
        !item.expandable && !item.active && /\b(chapter|prologue)\s*(1|one)?\b/i.test(item.label)
      );
      if (chapterIndex < 0) {
        chapterIndex = items.findIndex(item => !item.expandable && !item.active);
      }
      if (chapterIndex < 0) {
        chapterIndex = items.findIndex(item => item.expandable && !item.active);
      }
      if (chapterIndex < 0) {
        // The only rendered TOC row is already active. Close the sidebar and
        // let the physical page-turn loop below move to prose.
        await closeSidebarLikeUser(page);
        break;
      }
      // A Playwright click re-resolves the nth row if Grimmory replaces the
      // TOC DOM during its expansion animation. A separate scroll/visibility
      // action would hold a stale element handle and make that normal render
      // transition look like a product failure.
      await chapterRows.nth(chapterIndex).click();
      await page.waitForTimeout(250);
    }
    await expect(page.locator('.sidebar')).toHaveCount(0);
    await page.waitForTimeout(500);
  }
  for (let attempt = 0; !points && attempt < 20; attempt += 1) {
    try {
      points = await selectionDragPoints(page);
      break;
    } catch (error) {
      if (!String(error).includes('no visible selectable prose')) throw error;
      await page.keyboard.press('PageDown');
      await page.waitForTimeout(300);
    }
  }
  if (!points) throw new Error('could not reach selectable prose through the table of contents and 20 user page turns');
  const popup = page.locator('.text-selection-popup');
  let physicalSelectionWorked = false;
  for (let attempt = 0; attempt < 3 && !physicalSelectionWorked; attempt += 1) {
    await assertVisibleDragPoints(page, points);
    if (process.env.GRIMMORY_SELECTION_DIAGNOSTICS === '1') {
      console.error(`selection-coordinates ${JSON.stringify(points)}`);
    }
    await page.mouse.move(points.start.x, points.start.y);
    await page.mouse.down();
    await page.waitForTimeout(100);
    await page.mouse.move(points.end.x, points.end.y, { steps: 30 });
    await page.waitForTimeout(200);
    await page.mouse.up();
    physicalSelectionWorked = await popup.waitFor({ state: 'visible', timeout: 3_000 })
      .then(() => true, () => false);
    if (!physicalSelectionWorked) {
      await page.keyboard.press('PageDown');
      await page.waitForTimeout(500);
      points = await selectionDragPoints(page);
    }
  }
  await expect(popup, 'physical mouse drag must create Grimmory selection UI').toBeVisible();
  const text = await page.locator('foliate-view').evaluate(view => {
    const contents = view?.renderer?.getContents?.() || [];
    for (const { doc } of contents) {
      const text = doc.defaultView?.getSelection?.()?.toString?.().trim();
      if (text) return text;
    }
    return '';
  });
  expect(text.length).toBeGreaterThan(0);
  return { text, method: 'physical-mouse-drag', recovery };
}

function captureMutation(page, method, urlPart) {
  return page.waitForResponse(response =>
    response.request().method() === method && response.url().includes(urlPart)
  );
}

async function closeSidebarLikeUser(page) {
  const overlay = page.locator('.sidebar-overlay');
  const sidebar = page.locator('.sidebar');
  const [overlayBox, sidebarBox] = await Promise.all([
    overlay.boundingBox(), sidebar.boundingBox()
  ]);
  if (!overlayBox || !sidebarBox) throw new Error('reader sidebar and overlay must both be visible');
  // Highlights/contents opens on the left; Notes opens on the right. Choose a
  // point on the dimmed page that is geometrically outside the actual panel,
  // rather than assuming either orientation.
  const candidates = [overlayBox.x + 10, overlayBox.x + overlayBox.width - 10];
  const x = candidates.find(candidate =>
    candidate < sidebarBox.x || candidate > sidebarBox.x + sidebarBox.width
  );
  if (x === undefined) throw new Error('reader overlay exposes no click point outside the sidebar');
  await page.mouse.click(x, overlayBox.y + overlayBox.height / 2);
  await expect(page.locator('.sidebar')).toHaveCount(0);
}

async function createHighlightLikeUser(page) {
  const selection = await selectRenderedTextLikeUser(page);
  await page.locator('.text-selection-popup .annotation-container > .action-btn').click();
  await page.locator('.annotation-options .style-btn[title="Highlight"]').click();
  await page.locator('.annotation-options .color-btn[title="Yellow"]').click();
  const saved = captureMutation(page, 'POST', '/api/v1/annotations');
  await page.locator('.popup-backdrop').click({ position: { x: 5, y: 5 } });
  const response = await saved;
  expect(response.ok()).toBeTruthy();
  const annotation = await response.json();
  // ReaderViewManagerService serializes `range.toString().trim()` and the
  // physical-selection helper reads that same complete DOM Selection contract.
  // Comparing anything less than the entire string can hide a cross-node or
  // Unicode boundary error in the CFI that was actually uploaded.
  expect(annotation.text).toBe(selection.text);
  expect(annotation.cfi).toMatch(/^epubcfi\(/);
  expect(annotation.style).toBe('highlight');
  annotation.selectionMethod = selection.method;
  annotation.selectionRecovery = selection.recovery;
  return annotation;
}

async function deleteHighlightLikeUser(page, annotation) {
  // The sidebar is a public reader control and is more reliable than trying to
  // reproduce the exact text drag after pagination has shifted.
  await page.locator('.reader-header button[title="Chapters"]').click();
  await page.locator('.sidebar .tabs .tab').filter({ hasText: 'Highlights' }).click();
  const row = await exactHighlightRow(page, annotation.text);
  await expect(row).toBeVisible();
  const deleted = captureMutation(page, 'DELETE', `/api/v1/annotations/${annotation.id}`);
  await row.locator('.delete-btn').click();
  expect((await deleted).ok()).toBeTruthy();
  await expect(row).toHaveCount(0);
  await closeSidebarLikeUser(page);
}

async function exactHighlightRow(page, text) {
  const rows = page.locator('.sidebar .highlight-item');
  await expect(rows.first()).toBeVisible();
  const wanted = `"${text}"`;
  const matches = [];
  for (let index = 0; index < await rows.count(); index += 1) {
    const rendered = await rows.nth(index).locator('.highlight-text').textContent();
    if (rendered === wanted) matches.push(index);
  }
  expect(matches, 'Highlights sidebar must contain one exact whole-text row').toHaveLength(1);
  return rows.nth(matches[0]);
}

async function resolveLoadedCfiRange(page, cfi) {
  return page.locator('foliate-view').evaluate(async (view, wantedCfi) => {
    const resolved = view?.resolveNavigation?.(wantedCfi);
    if (!resolved || !Number.isInteger(resolved.index) || typeof resolved.anchor !== 'function') {
      throw new Error('Foliate could not independently resolve the device-origin CFI');
    }
    const deadline = Date.now() + 10_000;
    let content;
    while (Date.now() < deadline) {
      content = (view.renderer?.getContents?.() || [])
        .find(item => item.index === resolved.index && item.doc);
      if (content) break;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    if (!content) throw new Error('visible annotation navigation did not load the resolved Foliate section');
    const range = resolved.anchor(content.doc);
    const NativeRange = content.doc.defaultView?.Range;
    if (!NativeRange || !(range instanceof NativeRange)) {
      throw new Error('device-origin CFI did not resolve to an iframe-native DOM Range');
    }
    const inlineTags = new Set([
      'a', 'abbr', 'b', 'bdi', 'bdo', 'cite', 'code', 'data', 'dfn', 'em',
      'font', 'i', 'kbd', 'mark', 'q', 'rp', 'rt', 'ruby', 's', 'samp',
      'small', 'span', 'strong', 'sub', 'sup', 'time', 'u', 'var'
    ]);
    const leafBlock = node => {
      if (node?.nodeType !== 3) return { element: null, inlineAncestry: [] };
      let element = node.parentElement;
      const inlineAncestry = [];
      while (element && inlineTags.has(element.localName?.toLowerCase())) {
        inlineAncestry.unshift(element);
        element = element.parentElement;
      }
      return { element, inlineAncestry };
    };
    const elementPath = element => {
      const segments = [];
      for (let current = element; current; current = current.parentElement) {
        const name = current.localName?.toLowerCase();
        if (!name) break;
        const siblings = current.parentElement
          ? [...current.parentElement.children].filter(item => item.localName === current.localName)
          : [current];
        segments.unshift(`${name}[${siblings.indexOf(current) + 1}]`);
      }
      return `/${segments.join('/')}`;
    };
    const startLeaf = leafBlock(range.startContainer);
    const endLeaf = leafBlock(range.endContainer);
    const endpointsAreTextNodes = range.startContainer?.nodeType === 3 &&
      range.endContainer?.nodeType === 3;
    const crossesDomNodeBoundary = endpointsAreTextNodes &&
      range.startContainer !== range.endContainer;
    const sameInlineAncestry = startLeaf.inlineAncestry.length ===
      endLeaf.inlineAncestry.length && startLeaf.inlineAncestry.every(
      (element, index) => element === endLeaf.inlineAncestry[index]);
    const crossesInlineElementBoundary = crossesDomNodeBoundary && !sameInlineAncestry;
    const sameLeafBlock = endpointsAreTextNodes && !!startLeaf.element &&
      startLeaf.element === endLeaf.element;
    const acceptsSameLeafBlockInlineRange = endpointsAreTextNodes &&
      crossesDomNodeBoundary && crossesInlineElementBoundary && sameLeafBlock;
    return {
      text: range.toString(),
      collapsed: range.collapsed,
      sectionIndex: resolved.index,
      startContainerType: range.startContainer?.nodeType ?? null,
      endContainerType: range.endContainer?.nodeType ?? null,
      endpointsAreTextNodes,
      crossesDomNodeBoundary,
      crossesInlineElementBoundary,
      sameLeafBlock,
      acceptsSameLeafBlockInlineRange,
      startLeafBlockPath: startLeaf.element ? elementPath(startLeaf.element) : null,
      endLeafBlockPath: endLeaf.element ? elementPath(endLeaf.element) : null,
      startInlineAncestryPaths: startLeaf.inlineAncestry.map(elementPath),
      endInlineAncestryPaths: endLeaf.inlineAncestry.map(elementPath)
    };
  }, cfi);
}

async function deleteAllHighlightsLikeUser(page) {
  await page.mouse.move(720, 1);
  await page.locator('.reader-header button[title="Chapters"]').click();
  const highlightsTab = page.locator('.sidebar .tabs .tab').filter({ hasText: 'Highlights' });
  await highlightsTab.click();
  await expect(highlightsTab).toHaveClass(/active/);
  await page.locator('.sidebar .highlight-item, .sidebar .empty-state').first()
    .waitFor({ state: 'visible' });
  const rows = page.locator('.sidebar .highlight-item');
  while (await rows.count()) {
    const deleted = captureMutation(page, 'DELETE', '/api/v1/annotations/');
    await rows.first().locator('.delete-btn').click();
    expect((await deleted).ok()).toBeTruthy();
  }
  await closeSidebarLikeUser(page);
}

async function createNoteLikeUser(page, noteText) {
  const selection = await selectRenderedTextLikeUser(page);
  // The localized tooltip capitalization changed in the pinned UI; the
  // visible note glyph is the stable public control.
  await page.locator('.text-selection-popup button.action-btn')
    .filter({ has: page.locator('app-reader-icon[name="note"]') }).click();
  await expect(page.locator('#noteContent')).toBeVisible();
  await page.locator('#noteContent').fill(noteText);
  const saved = captureMutation(page, 'POST', '/api/v2/book-notes');
  await page.locator('.dialog-footer .btn-primary').click();
  const response = await saved;
  expect(response.ok()).toBeTruthy();
  const note = await response.json();
  expect(note.noteContent).toBe(noteText);
  expect(note.selectedText).toBe(selection.text);
  expect(note.cfi).toMatch(/^epubcfi\(/);
  note.selectionMethod = selection.method;
  note.selectionRecovery = selection.recovery;
  return note;
}

async function deleteAllNotesLikeUser(page) {
  await page.keyboard.press('n');
  await page.locator('.sidebar .note-item, .sidebar .empty-state').first()
    .waitFor({ state: 'visible' });
  const rows = page.locator('.sidebar .note-item');
  while (await rows.count()) {
    const deleted = captureMutation(page, 'DELETE', '/api/v2/book-notes/');
    await rows.first().locator('.delete-btn').click();
    expect((await deleted).ok()).toBeTruthy();
  }
  await closeSidebarLikeUser(page);
}

async function editAndDeleteNoteLikeUser(page, note, updatedText) {
  await page.keyboard.press('n');
  const row = page.locator('.sidebar .note-item').filter({ hasText: note.noteContent });
  await expect(row).toBeVisible();
  await row.locator('.edit-btn').click();
  await expect(page.locator('#noteContent')).toHaveValue(note.noteContent);
  await page.locator('#noteContent').fill(updatedText);
  const updated = captureMutation(page, 'PUT', `/api/v2/book-notes/${note.id}`);
  await page.locator('.dialog-footer .btn-primary').click();
  expect((await updated).ok()).toBeTruthy();
  // Saving the edit closes Grimmory's Notes sidebar. Reopen it with the
  // reader's public keyboard shortcut before checking and deleting the result.
  await page.keyboard.press('n');
  const updatedRow = page.locator('.sidebar .note-item').filter({ hasText: updatedText });
  await expect(updatedRow).toBeVisible();
  const deleted = captureMutation(page, 'DELETE', `/api/v2/book-notes/${note.id}`);
  await updatedRow.locator('.delete-btn').click();
  expect((await deleted).ok()).toBeTruthy();
  await expect(updatedRow).toHaveCount(0);
  await closeSidebarLikeUser(page);
}

async function renderedCoverFingerprint(image) {
  await expect(image).toBeVisible();
  const rendered = await image.evaluate(async node => {
    if (!node.complete || !node.naturalWidth || !node.naturalHeight) {
      throw new Error('rendered cover image has not decoded');
    }
    const response = await fetch(node.currentSrc, { credentials: 'same-origin' });
    if (!response.ok) throw new Error(`rendered cover response failed: ${response.status}`);
    const bytes = new Uint8Array(await response.arrayBuffer());
    let binary = '';
    const chunkSize = 0x8000;
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
      binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
    }
    return {
      width: node.naturalWidth,
      height: node.naturalHeight,
      aspectRatio: node.naturalWidth / node.naturalHeight,
      base64: btoa(binary)
    };
  });
  // Hash the decoded source of the visible, fully loaded element. This is the
  // response the browser painted (not a guessed API URL); using its uncropped
  // pixels avoids CSS card sizing changing a book's identity hash. Pillow is
  // also what generated the cache reference, so both sides use exactly the
  // same grayscale/Lanczos/dHash algorithm.
  const renderedBytes = Buffer.from(rendered.base64, 'base64');
  const python = process.env.PYTHON_EXECUTABLE || process.env.PYTHON ||
    (process.platform === 'win32' ? 'python' : 'python3');
  const script = [
    'import io, json, sys',
    'from PIL import Image, ImageOps',
    'im = ImageOps.exif_transpose(Image.open(io.BytesIO(sys.stdin.buffer.read()))).convert("L")',
    'im = im.resize((17, 16), Image.Resampling.LANCZOS)',
    'px = list(im.getdata())',
    'bits = "".join("1" if px[y*17+x] > px[y*17+x+1] else "0" for y in range(16) for x in range(16))',
    'print(json.dumps({"differenceHash256": f"{int(bits, 2):064x}"}))'
  ].join('; ');
  const result = spawnSync(python, ['-c', script], {
    input: renderedBytes, encoding: 'utf8', maxBuffer: 1024 * 1024
  });
  if (result.status !== 0) {
    throw new Error(`visible cover fingerprint failed (${result.status}): ${String(result.stderr).trim()}`);
  }
  const { base64: _, ...dimensions } = rendered;
  return { ...dimensions, ...JSON.parse(result.stdout) };
}

function differenceHashDistance(left, right) {
  if (!/^[0-9a-f]{64}$/i.test(left || '') || !/^[0-9a-f]{64}$/i.test(right || '')) return 257;
  const bitCounts = [0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4];
  let distance = 0;
  for (let index = 0; index < 64; index += 1) {
    distance += bitCounts[Number.parseInt(left[index], 16) ^ Number.parseInt(right[index], 16)];
  }
  return distance;
}

async function expectRenderedCoverLike(image, expected, label) {
  const reference = expected.coverVisualFingerprint;
  expect(reference?.differenceHash256, `${label} requires a cached 256-bit cover fingerprint`)
    .toMatch(/^[0-9a-f]{64}$/i);
  const actual = await renderedCoverFingerprint(image);
  expect(actual.width, `${label} cover width`).toBeGreaterThan(0);
  expect(actual.height, `${label} cover height`).toBeGreaterThan(0);
  expect(Math.abs(actual.aspectRatio - Number(reference.aspectRatio)), `${label} cover aspect ratio`)
    .toBeLessThanOrEqual(0.01);
  expect(
    differenceHashDistance(actual.differenceHash256, reference.differenceHash256),
    `${label} cover must match cached art, not merely have the right shape`
  ).toBeLessThanOrEqual(20);
  return actual;
}

module.exports = {
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
  isDistinctProgress,
  progressPercentageAtServerPrecision,
  persistedProgressIsAtTarget,
  readerLocationChanged,
  deriveGoTargetContainment
};
