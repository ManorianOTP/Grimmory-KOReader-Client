const crypto = require('node:crypto');
const zlib = require('node:zlib');

const METADATA_FIELDS = [
  'title', 'subtitle', 'publisher', 'publishedDate', 'description',
  'seriesName', 'seriesNumber', 'seriesTotal', 'isbn13', 'isbn10',
  'pageCount', 'language', 'narrator', 'abridged', 'asin',
  'amazonRating', 'amazonReviewCount', 'goodreadsId', 'comicvineId',
  'goodreadsRating', 'goodreadsReviewCount', 'hardcoverId',
  'hardcoverBookId', 'hardcoverRating', 'hardcoverReviewCount',
  'lubimyczytacRating', 'googleId', 'lubimyczytacId', 'ranobedbId',
  'ranobedbRating', 'audibleId', 'audibleRating', 'audibleReviewCount',
  'authors', 'categories', 'moods', 'tags', 'bookReviews', 'isFixedLayout',
  'ageRating', 'contentRating'
];

const ARRAY_FIELDS = new Set(['authors', 'categories', 'moods', 'tags', 'bookReviews']);

const PROVIDER_IDENTIFIERS = {
  amazon: 'asin', goodreads: 'goodreadsId', google: 'googleId',
  hardcover: 'hardcoverId', comicvine: 'comicvineId', douban: 'doubanId',
  lubimyczytac: 'lubimyczytacId', ranobedb: 'ranobedbId', audible: 'audibleId'
};

function canonicalProvider(value) {
  return String(value || '').toLowerCase().replace(/[^a-z0-9]/g, '');
}

function normalizedText(value) {
  return String(value ?? '').replace(/\s+/g, ' ').trim();
}

function normalizeSearchTerm(value) {
  let result = String(value || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '');
  result = result.replace(/ø/gi, 'o').replace(/ł/gi, 'l').replace(/æ/gi, 'ae')
    .replace(/œ/gi, 'oe').replace(/ß/g, 'ss');
  return result.replace(/[!@$%^&*_=|~`<>?/";']/g, '')
    .replace(/\s+/g, ' ').trim().toLowerCase();
}

function expectedWebSearchTitles(books, query) {
  const needle = normalizeSearchTerm(query);
  if (needle.length < 2) return books.map(book => book.expectedMetadata?.title || '').sort();
  return books.filter(book => {
    const metadata = book.expectedMetadata || {};
    const identifiers = metadata.identifiers || {};
    const fields = [
      metadata.title, metadata.series?.name,
      ...(metadata.authors || []), ...(metadata.genres || metadata.categories || []),
      identifiers.isbn10, identifiers.isbn13,
      book.primaryFile?.fileName, book.fileName
    ];
    return fields.some(value => normalizeSearchTerm(value).includes(needle));
  }).map(book => book.expectedMetadata.title).sort();
}

function seriesAuthorsDisplay(authors) {
  if (!authors.length) return '';
  return authors.length <= 2 ? authors.join(', ') : `${authors.slice(0, 2).join(', ')} +${authors.length - 2}`;
}

function cleanReview(value) {
  if (Array.isArray(value)) return value.map(cleanReview);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value)
    .filter(([key]) => key !== 'id')
    .map(([key, child]) => [key, cleanReview(child)]));
}

function stableMetadataProjection(metadata) {
  const output = {};
  for (const field of METADATA_FIELDS) {
    const value = metadata?.[field];
    if (ARRAY_FIELDS.has(field)) {
      const items = Array.isArray(value) ? value : [];
      output[field] = field === 'bookReviews' ? cleanReview(items) : items;
    } else {
      // The form serializes an unset scalar as either an empty string or an
      // omitted property, while the API commonly returns null. They represent
      // the same cleared field; normalizing them also prevents stale values
      // from escaping the complete provider-projection comparison below.
      output[field] = value === undefined || value === '' ? null : value;
    }
  }
  for (const field of ['categories', 'moods', 'tags']) {
    if (Array.isArray(output[field])) {
      output[field] = [...output[field]].sort((left, right) =>
        String(left).localeCompare(String(right), 'en', { sensitivity: 'base' }));
    }
  }
  return output;
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key =>
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function projectionSha256(value) {
  return crypto.createHash('sha256').update(canonicalJson(value), 'utf8').digest('hex');
}

function requireEqual(actual, expected, label) {
  const left = canonicalJson(actual);
  const right = canonicalJson(expected);
  if (left !== right) throw new Error(`${label} differs`);
}

function assertProviderCopyPersisted(source, outboundWrapper, persisted, provider, providerItemId) {
  const outbound = outboundWrapper?.metadata;
  if (!source || typeof source !== 'object' || !outbound || typeof outbound !== 'object' ||
      !persisted || typeof persisted !== 'object') {
    throw new Error('provider/source/outbound/persisted metadata objects are required');
  }
  const sourceProjection = stableMetadataProjection(source);
  const outboundProjection = stableMetadataProjection(outbound);
  const persistedProjection = stableMetadataProjection(persisted);

  // Compare the complete allowlisted provider-owned projection. Generated
  // book/database fields and cover-cache timestamps are deliberately absent.
  // Because missing fields normalize explicitly, a stale or invented value in
  // both the request and persisted response cannot bless itself.
  requireEqual(outboundProjection, sourceProjection, 'complete Copy All provider projection');
  requireEqual(persistedProjection, outboundProjection, 'full persisted metadata projection');

  const providerKey = canonicalProvider(provider);
  const identifierField = PROVIDER_IDENTIFIERS[providerKey];
  if (!identifierField) throw new Error(`unsupported provider ${provider}`);
  if (String(source[identifierField] ?? '') !== String(providerItemId) ||
      String(outbound[identifierField] ?? '') !== String(providerItemId) ||
      String(persisted[identifierField] ?? '') !== String(providerItemId)) {
    throw new Error('selected provider item identity differs from copied or persisted metadata');
  }
  if (source.thumbnailUrl) {
    if (outbound.thumbnailUrl !== source.thumbnailUrl) {
      throw new Error('Copy All did not retain the selected provider cover URL');
    }
  } else if (outbound.thumbnailUrl) {
    throw new Error('Copy All associated an unexpected cover with a coverless provider result');
  }
  return {
    selectedProjectionSha256: projectionSha256(sourceProjection),
    persistedProjectionSha256: projectionSha256(persistedProjection)
  };
}

function paeth(left, above, upperLeft) {
  const estimate = left + above - upperLeft;
  const leftDistance = Math.abs(estimate - left);
  const aboveDistance = Math.abs(estimate - above);
  const upperLeftDistance = Math.abs(estimate - upperLeft);
  return leftDistance <= aboveDistance && leftDistance <= upperLeftDistance ? left
    : (aboveDistance <= upperLeftDistance ? above : upperLeft);
}

function decodeRgbaPng(bytes) {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  if (!Buffer.isBuffer(bytes) || !bytes.subarray(0, 8).equals(signature)) {
    throw new Error('cover screenshot is not a PNG');
  }
  let width; let height; let bitDepth; let colorType;
  const idat = [];
  for (let offset = 8; offset < bytes.length;) {
    const length = bytes.readUInt32BE(offset);
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    const data = bytes.subarray(offset + 8, offset + 8 + length);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0); height = data.readUInt32BE(4);
      bitDepth = data[8]; colorType = data[9];
    } else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    offset += length + 12;
  }
  if (!width || !height || bitDepth !== 8 || ![2, 6].includes(colorType)) {
    throw new Error('cover screenshot PNG must be 8-bit RGB or RGBA');
  }
  const channels = colorType === 6 ? 4 : 3;
  const stride = width * channels;
  const inflated = zlib.inflateSync(Buffer.concat(idat));
  const pixels = Buffer.alloc(width * height * 4);
  let inputOffset = 0;
  let previous = Buffer.alloc(stride);
  for (let y = 0; y < height; y += 1) {
    const filter = inflated[inputOffset++];
    const row = Buffer.from(inflated.subarray(inputOffset, inputOffset + stride));
    inputOffset += stride;
    for (let index = 0; index < stride; index += 1) {
      const left = index >= channels ? row[index - channels] : 0;
      const above = previous[index];
      const upperLeft = index >= channels ? previous[index - channels] : 0;
      if (filter === 1) row[index] = (row[index] + left) & 0xff;
      else if (filter === 2) row[index] = (row[index] + above) & 0xff;
      else if (filter === 3) row[index] = (row[index] + Math.floor((left + above) / 2)) & 0xff;
      else if (filter === 4) row[index] = (row[index] + paeth(left, above, upperLeft)) & 0xff;
      else if (filter !== 0) throw new Error(`unsupported PNG filter ${filter}`);
    }
    for (let x = 0; x < width; x += 1) {
      const source = x * channels;
      const target = (y * width + x) * 4;
      pixels[target] = row[source]; pixels[target + 1] = row[source + 1];
      pixels[target + 2] = row[source + 2]; pixels[target + 3] = channels === 4 ? row[source + 3] : 255;
    }
    previous = row;
  }
  return { width, height, pixels };
}

function coverVisualFingerprint(png) {
  const image = decodeRgbaPng(png);
  let bits = 0n;
  const grayscale = (x, y) => {
    const offset = (y * image.width + x) * 4;
    return image.pixels[offset] * 299 + image.pixels[offset + 1] * 587 + image.pixels[offset + 2] * 114;
  };
  for (let row = 0; row < 16; row += 1) {
    const y = Math.round(row * (image.height - 1) / 15);
    for (let column = 0; column < 16; column += 1) {
      const left = Math.round(column * (image.width - 1) / 16);
      const right = Math.round((column + 1) * (image.width - 1) / 16);
      bits = (bits << 1n) | (grayscale(left, y) > grayscale(right, y) ? 1n : 0n);
    }
  }
  return { differenceHash256: bits.toString(16).padStart(64, '0'), aspectRatio: image.width / image.height };
}

function hashDistance(left, right) {
  let bits = BigInt(`0x${left}`) ^ BigInt(`0x${right}`);
  let count = 0;
  while (bits) { count += Number(bits & 1n); bits >>= 1n; }
  return count;
}

function assertCoverFingerprint(selected, persisted) {
  const distance = hashDistance(selected.differenceHash256, persisted.differenceHash256);
  const aspectDelta = Math.abs(Number(selected.aspectRatio) - Number(persisted.aspectRatio));
  // Reuse the reviewed cover-cache verification contract: re-encoding may
  // alter integer dimensions, but not more than 20/256 dHash bits or 0.01 of
  // aspect ratio. This detects wrong cover association without demanding byte
  // identity from the server's image pipeline.
  if (distance > 20 || !Number.isFinite(aspectDelta) || aspectDelta > 0.01) {
    throw new Error('persisted cover fingerprint differs from selected provider cover');
  }
  return distance;
}

module.exports = {
  assertCoverFingerprint,
  assertProviderCopyPersisted,
  canonicalJson,
  coverVisualFingerprint,
  expectedWebSearchTitles,
  hashDistance,
  normalizeSearchTerm,
  normalizedText,
  projectionSha256,
  seriesAuthorsDisplay,
  stableMetadataProjection
};
