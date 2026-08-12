const test = require('node:test');
const assert = require('node:assert/strict');
const {
  assertCoverFingerprint,
  assertProviderCopyPersisted,
  expectedWebSearchTitles,
  seriesAuthorsDisplay
} = require('./metadata_exactness');

const provider = {
  title: 'Exact title', authors: ['One', 'Two'], categories: ['B', 'a'],
  description: 'The complete provider description.', googleId: 'edition-7',
  thumbnailUrl: 'https://provider.invalid/cover.jpg', bookReviews: [{ id: 9, body: 'Complete review' }]
};
const copied = {
  metadata: {
    ...provider, bookId: 42, categories: ['a', 'B'],
    bookReviews: [{ id: 100, body: 'Complete review' }]
  }
};
const persisted = { ...copied.metadata, thumbnailUrl: undefined };

test('full provider projection accepts only the exact selected edition and saved fields', () => {
  assert.doesNotThrow(() => assertProviderCopyPersisted(provider, copied, persisted, 'Google', 'edition-7'));
});

test('provider projection rejects truncation, extras, partial Copy All, and wrong association', () => {
  assert.throws(() => assertProviderCopyPersisted(provider, {
    metadata: { ...copied.metadata, description: provider.description.slice(0, 8) }
  }, persisted, 'Google', 'edition-7'), /complete Copy All/);
  assert.throws(() => assertProviderCopyPersisted(provider, copied, {
    ...persisted, tags: ['unexpected']
  }, 'Google', 'edition-7'), /full persisted/);
  assert.throws(() => assertProviderCopyPersisted(provider, {
    metadata: { ...copied.metadata, tags: ['unexpected'] }
  }, {
    ...persisted, tags: ['unexpected']
  }, 'Google', 'edition-7'), /complete Copy All/);
  assert.throws(() => assertProviderCopyPersisted(provider, copied, {
    ...persisted, googleId: 'another-edition'
  }, 'Google', 'edition-7'), /persisted metadata|identity/);
});

test('exact search result derivation keeps all matches and no extras', () => {
  const books = [
    { expectedMetadata: { title: 'One Exact Book', authors: ['A'], identifiers: {} } },
    { expectedMetadata: { title: 'Another', authors: ['One Exact Book Society'], identifiers: {} } },
    { expectedMetadata: { title: 'Unrelated', authors: ['B'], identifiers: {} } }
  ];
  assert.deepEqual(expectedWebSearchTitles(books, 'One Exact Book'), ['Another', 'One Exact Book']);
  assert.notDeepEqual([...expectedWebSearchTitles(books, 'One Exact Book'), 'Unrelated'],
    ['Another', 'One Exact Book']);
});

test('series card summary is exact rather than global author containment', () => {
  assert.equal(seriesAuthorsDisplay(['A', 'B', 'C']), 'A, B +1');
  assert.notEqual(seriesAuthorsDisplay(['A', 'C', 'B']), 'A, B +1');
});

test('cover fingerprint rejects a wrong association and accepts the pinned re-encode budget', () => {
  const expected = { differenceHash256: '0'.repeat(64), aspectRatio: 2 / 3 };
  const reencoded = { differenceHash256: `${'0'.repeat(63)}f`, aspectRatio: 2 / 3 };
  const wrong = { differenceHash256: 'f'.repeat(64), aspectRatio: 2 / 3 };
  assert.equal(assertCoverFingerprint(expected, reencoded), 4);
  assert.equal(assertCoverFingerprint(expected, { ...reencoded, aspectRatio: (2 / 3) + 0.005 }), 4);
  assert.throws(() => assertCoverFingerprint(expected, wrong), /differs/);
  assert.throws(() => assertCoverFingerprint(expected, { ...expected, aspectRatio: 1 }), /differs/);
});
