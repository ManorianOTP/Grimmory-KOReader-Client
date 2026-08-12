const test = require('node:test');
const assert = require('node:assert/strict');
const {
  isDistinctProgress,
  progressPercentageAtServerPrecision,
  persistedProgressIsAtTarget,
  readerLocationChanged,
  deriveGoTargetContainment
} = require('./browser_helpers');

const progress = (cfi, percentage) => ({
  bookId: 1,
  epubProgress: { cfi, href: 'chapter.xhtml', percentage }
});

test('progress transition requires both a different CFI and percentage', () => {
  const baseline = progress('epubcfi(/6/2!/4/2:1)', 2.776);
  assert.equal(isDistinctProgress(baseline, progress(baseline.epubProgress.cfi, 5.6)), false);
  assert.equal(isDistinctProgress(baseline, progress('epubcfi(/6/2!/4/2:9)', 2.776)), false);
  assert.equal(isDistinctProgress(baseline, progress('epubcfi(/6/2!/4/2:9)', 5.6)), true);
  assert.equal(isDistinctProgress(null, progress('epubcfi(/6/2!/4/2:9)', 5.6)), false);
});

test('progress comparison models Grimmory v3.3.1 MariaDB FLOAT/JDBC persistence exactly', () => {
  assert.equal(progressPercentageAtServerPrecision(5.552153709033263), 5.55215);
  assert.equal(progressPercentageAtServerPrecision(0.048974891144804356), 0.0489749);
});

test('visible reader movement recognizes text, media, and percentage changes', () => {
  const baseline = { percentage: 100, visibleContent: { text: '', media: 'cover-a' } };
  assert.equal(readerLocationChanged(baseline, baseline), false);
  assert.equal(readerLocationChanged(baseline, {
    percentage: 100,
    visibleContent: { text: 'Chapter one', media: 'cover-a' }
  }), true);
  assert.equal(readerLocationChanged(baseline, {
    percentage: 100,
    visibleContent: { text: '', media: 'cover-b' }
  }), true);
  assert.equal(readerLocationChanged(baseline, {
    percentage: 95,
    visibleContent: { text: '', media: 'cover-a' }
  }), true);
});

test('already-at-target detection uses the exact persisted server precision', () => {
  assert.equal(persistedProgressIsAtTarget(progress('epubcfi(/6/2!/4/2:9)', 100), 100), true);
  assert.equal(persistedProgressIsAtTarget(progress('epubcfi(/6/2!/4/2:9)', 99.99999), 100), true);
  assert.equal(persistedProgressIsAtTarget(progress('epubcfi(/6/2!/4/2:9)', 99.99), 100), false);
  assert.equal(persistedProgressIsAtTarget(null, 100), false);
});

test('Go target containment resolves the exact rendered page without tolerance', () => {
  const proof = deriveGoTargetContainment(0.4, {
    sectionFractions: [0, 0.1, 0.5, 1],
    resolvedSection: 1,
    visibleSection: 1,
    resolvedAnchor: 0.75,
    rendererPage: 8,
    rendererPages: 12,
    lastFraction: 0.42,
    lastCfi: 'epubcfi(/6/4!/4/2:9)',
    scrolled: false
  });
  assert.equal(proof.textPages, 10);
  assert.equal(proof.contentPage, 7);
  assert.equal(proof.expectedPage, 7);
  assert.equal(proof.pageStart, 0.38);
  assert.equal(proof.pageEnd, 0.42);
  assert.equal(proof.anchorStart, 6.5 / 9);
  assert.equal(proof.anchorEnd, 7.5 / 9);
  assert.equal(proof.anchorContained, true);
  assert.equal(proof.targetContained, true);
});

test('Go 80 regression accepts Foliate page snapping to POST 80.519836 and visible 81', () => {
  const postedFraction = 0.8051983616707148;
  const state = {
    sectionFractions: [
      0, 0.08328230563549895, 0.1665646112709979, 0.24984691690649685,
      0.3331292225419958, 0.41641152817749477, 0.4996938338129937,
      0.5829761394484927, 0.6662584450839916, 0.7495407507194906,
      0.8330271671463271, 0.9165135835731635, 1
    ],
    resolvedSection: 9,
    visibleSection: 9,
    resolvedAnchor: 0.6044007090031202,
    rendererPage: 2,
    rendererPages: 5,
    lastFraction: postedFraction,
    lastCfi: 'epubcfi(/6/20!/4/2[chapter-10],/32[p13],/58[p25]/1:272)',
    scrolled: false
  };
  const proof = deriveGoTargetContainment(0.8, state);
  assert.equal(proof.contentPage, 1);
  assert.equal(proof.expectedPage, 1);
  assert.equal(proof.anchorStart, 0.25);
  assert.equal(proof.anchorEnd, 0.75);
  assert.equal(proof.anchorContained, true);
  assert.equal(proof.targetContained, true);
  assert.equal(proof.pageEnd, 0.8051983616707149);
  assert.notEqual(proof.pageEnd, proof.lastFraction);
  assert.equal(proof.reportedPageContainsRequestedFraction, true);
  assert.equal(proof.reportedPageContainsLastFraction, true);
  assert.equal(proof.lastFraction * 100, 80.51983616707147);
  assert.equal(Math.round(proof.lastFraction * 100), 81);
});

test('Go target uses the exact resolver page even when reported progress interval excludes it', () => {
  const proof = deriveGoTargetContainment(0.79, {
    sectionFractions: [0, 0.7511983616707147, 0.8111983616707147, 1],
    resolvedSection: 1,
    visibleSection: 1,
    resolvedAnchor: 0.84,
    rendererPage: 9,
    rendererPages: 12,
    lastFraction: 0.8051983616707147,
    lastCfi: 'epubcfi(/6/20!/4/2:1)',
    scrolled: false
  });
  assert.equal(proof.anchorContained, true);
  assert.equal(proof.targetContained, true);
  assert.equal(proof.reportedPageContainsRequestedFraction, false);
  assert.equal(proof.reportedPageContainsLastFraction, true);
});

test('real EPUB regression: Go 80 lands in page 1 snap cell despite its later relocation span', () => {
  const proof = deriveGoTargetContainment(0.8, {
    sectionFractions: [
      ...Array.from({ length: 88 }, (_, index) => index / 110),
      0.7983005271526361,
      0.8057483485665569
    ],
    resolvedSection: 88,
    visibleSection: 88,
    resolvedAnchor: 0.22818388800081543,
    rendererPage: 2,
    rendererPages: 6,
    lastFraction: 0.8020244378595965,
    lastCfi: 'epubcfi(/6/178!/4/2/2[id109],/72,/158/5:108)',
    scrolled: false
  });
  assert.equal(proof.textPages, 4);
  assert.equal(proof.contentPage, 1);
  assert.equal(proof.expectedPage, 1);
  assert.equal(proof.anchorStart, 1 / 6);
  assert.equal(proof.anchorEnd, 0.5);
  assert.equal(proof.anchorContained, true);
  assert.equal(proof.targetContained, true);
  assert.equal(proof.pageStart, 0.8001624825061163);
  assert.equal(proof.pageEnd, 0.8020244378595965);
  assert.equal(proof.reportedPageContainsRequestedFraction, false);
  assert.equal(proof.reportedPageContainsLastFraction, true);
});

test('Go target containment exposes a renderer page different from the resolved page', () => {
  const proof = deriveGoTargetContainment(0.8, {
    sectionFractions: [0, 0.75, 0.82, 1],
    resolvedSection: 1,
    visibleSection: 1,
    resolvedAnchor: 0.84,
    rendererPage: 8,
    rendererPages: 12,
    lastFraction: 0.799,
    lastCfi: 'epubcfi(/6/20!/4/2:1)',
    scrolled: false
  });
  assert.notEqual(proof.contentPage, proof.expectedPage);
  assert.equal(proof.targetContained, false);
});
