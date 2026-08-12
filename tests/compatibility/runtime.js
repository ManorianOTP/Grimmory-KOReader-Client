const fs = require('node:fs');
const path = require('node:path');

function requireText(value, name) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new Error(`compatibility runtime requires ${name}`);
  }
  return value.trim();
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function manifestBooks(runtime, runtimeFile) {
  if (Array.isArray(runtime.books)) return runtime.books;
  if (!runtime.sourceManifest) return [];
  const manifestPath = path.resolve(path.dirname(runtimeFile), runtime.sourceManifest);
  const manifest = readJson(manifestPath);
  return Array.isArray(manifest) ? manifest : (manifest.books || []);
}

function normalizeBook(raw, index) {
  const expectedMetadata = raw.expectedMetadata || raw.metadata || {};
  const serverBookId = Number(raw.serverBookId ?? raw.bookId ?? raw.id);
  if (!Number.isInteger(serverBookId) || serverBookId <= 0) {
    throw new Error(`runtime book ${index} has no positive serverBookId`);
  }
  const kind = raw.kind === 'real' || raw.kind === 'private-real-epub' ? 'private' : raw.kind;
  if (kind !== 'synthetic' && kind !== 'private') {
    throw new Error(`runtime book ${serverBookId} kind must be synthetic or private`);
  }
  const title = requireText(
    expectedMetadata.title ?? raw.title ?? raw.serverTitle,
    `books[${index}].expectedMetadata.title`
  );
  return {
    ...raw,
    serverBookId,
    kind,
    alias: raw.alias || `${kind}-${serverBookId}`,
    expectedMetadata: { ...expectedMetadata, title }
  };
}

function loadRuntime() {
  const runtimeFile = path.resolve(requireText(
    process.env.GRIMMORY_COMPAT_RUNTIME,
    'GRIMMORY_COMPAT_RUNTIME (path to the harness runtime JSON)'
  ));
  const raw = readJson(runtimeFile);
  const books = manifestBooks(raw, runtimeFile).map(normalizeBook);
  const synthetic = books.filter(book => book.kind === 'synthetic');
  const privateBooks = books.filter(book => book.kind === 'private');
  if (!synthetic.length) throw new Error('browser journeys require at least one synthetic EPUB');
  if (privateBooks.length !== 8) {
    throw new Error(`browser journeys require exactly eight private EPUBs, found ${privateBooks.length}`);
  }
  const requestedAliases = (process.env.GRIMMORY_COMPAT_BOOK_ALIASES || '')
    .split(',').map(value => value.trim()).filter(Boolean);
  const readerBooks = requestedAliases.length
    ? requestedAliases.map(alias => {
      const matches = books.filter(book => book.alias === alias);
      if (matches.length !== 1) {
        throw new Error(`requested browser-journey alias ${alias} matched ${matches.length} books`);
      }
      return matches[0];
    })
    : [...synthetic, ...privateBooks];
  if (new Set(readerBooks.map(book => book.alias)).size !== readerBooks.length) {
    throw new Error('requested browser-journey aliases must be unique');
  }
  return {
    ...raw,
    runtimeFile,
    baseUrl: requireText(raw.baseUrl ?? raw.url, 'baseUrl').replace(/\/$/, ''),
    username: requireText(raw.username ?? raw.credentials?.username, 'username'),
    password: requireText(raw.password ?? raw.credentials?.password, 'password'),
    books,
    synthetic,
    privateBooks,
    // Every book-consuming journey executes its synthetic case and all real
    // books. Keeping the pairing in the runtime, rather than in test titles,
    // makes a missing private lane an immediate setup failure.
    readerBooks
  };
}

module.exports = { loadRuntime, normalizeBook };
