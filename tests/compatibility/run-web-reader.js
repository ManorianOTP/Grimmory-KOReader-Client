#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function usage(message) {
  if (message) console.error(`run-web-reader: ${message}`);
  console.error('Usage: node run-web-reader.js --runtime PATH [--output PATH] [--headful] [--list] [--grep TEXT] [--grep-invert TEXT] [--book-alias ALIAS ...] [--merge-checkpoints PATH] [--koreader-output PATH]');
  process.exit(2);
}

const args = process.argv.slice(2);
let runtime;
let output;
let headful = false;
let grep;
let grepInvert;
let listOnly = false;
let mergeCheckpoints;
let koreaderOutput;
const bookAliases = [];
for (let index = 0; index < args.length; index += 1) {
  const arg = args[index];
  if (arg === '--runtime') runtime = args[++index];
  else if (arg === '--output') output = args[++index];
  else if (arg === '--grep') {
    grep = args[++index];
    if (!grep) usage('--grep requires a value');
  } else if (arg === '--grep-invert') {
    grepInvert = args[++index];
    if (!grepInvert) usage('--grep-invert requires a value');
  } else if (arg === '--list') listOnly = true;
  else if (arg === '--book-alias') bookAliases.push(args[++index]);
  else if (arg === '--merge-checkpoints') mergeCheckpoints = args[++index];
  else if (arg === '--koreader-output') koreaderOutput = args[++index];
  else if (arg === '--headful') headful = true;
  else usage(`unknown argument ${arg}`);
}
if (!runtime) usage('--runtime is required');
if (bookAliases.some(alias => !alias)) usage('--book-alias requires a value');
runtime = path.resolve(runtime);
if (!fs.existsSync(runtime)) usage(`runtime does not exist: ${runtime}`);
output = path.resolve(output || path.join(path.dirname(runtime), 'web-reader'));
fs.mkdirSync(output, { recursive: true });
if (mergeCheckpoints) {
  mergeCheckpoints = path.resolve(mergeCheckpoints);
  if (!fs.existsSync(mergeCheckpoints)) usage(`checkpoint input does not exist: ${mergeCheckpoints}`);
}
if (koreaderOutput) {
  koreaderOutput = path.resolve(koreaderOutput);
  if (!fs.existsSync(koreaderOutput)) usage(`KOReader output does not exist: ${koreaderOutput}`);
}

function checkpointKey(checkpoint) {
  return `${checkpoint.journey}\u0000${checkpoint.alias}`;
}

function mergeCheckpointArtifact(oldFile, newFile) {
  const oldArtifact = JSON.parse(fs.readFileSync(oldFile, 'utf8'));
  const newArtifact = JSON.parse(fs.readFileSync(newFile, 'utf8'));
  if (oldArtifact.schemaVersion !== 2 || newArtifact.schemaVersion !== 2) {
    throw new Error('checkpoint merge requires schemaVersion 2 artifacts');
  }
  const replacements = new Map();
  for (const checkpoint of newArtifact.checkpoints || []) {
    const key = checkpointKey(checkpoint);
    if (replacements.has(key)) throw new Error(`new checkpoint artifact contains duplicate ${key}`);
    replacements.set(key, checkpoint);
  }
  if (!replacements.size) throw new Error('new checkpoint artifact contains no replacement checkpoints');
  const merged = [];
  const oldKeys = new Set();
  for (const checkpoint of oldArtifact.checkpoints || []) {
    const key = checkpointKey(checkpoint);
    if (oldKeys.has(key)) throw new Error(`checkpoint input contains duplicate ${key}`);
    oldKeys.add(key);
    merged.push(replacements.get(key) || checkpoint);
    replacements.delete(key);
  }
  for (const [key, checkpoint] of replacements) {
    if (oldKeys.has(key)) throw new Error(`checkpoint replacement was not unique: ${key}`);
    merged.push(checkpoint);
  }
  const oldOutcomes = oldArtifact.outcomeContract;
  const newOutcomes = newArtifact.outcomeContract;
  if (oldOutcomes?.schemaVersion !== 1 || newOutcomes?.schemaVersion !== 1 ||
      !Array.isArray(oldOutcomes.journeys) || !Array.isArray(newOutcomes.journeys)) {
    throw new Error('checkpoint merge requires schemaVersion 1 runtime outcome contracts');
  }
  const outcomeMap = new Map();
  for (const record of [...oldOutcomes.journeys, ...newOutcomes.journeys]) {
    if (!record || typeof record.journey !== 'string') {
      throw new Error('checkpoint outcome record has no journey identity');
    }
    const previous = outcomeMap.get(record.journey);
    if (!previous) {
      outcomeMap.set(record.journey, record);
      continue;
    }
    if (previous.schemaVersion !== record.schemaVersion ||
        JSON.stringify(previous.outcomes) !== JSON.stringify(record.outcomes)) {
      throw new Error(`checkpoint outcome contract changed for ${record.journey}`);
    }
    const aliases = [...new Set([
      ...(previous.coverageAliases || []), ...(record.coverageAliases || [])
    ])].sort();
    outcomeMap.set(record.journey, { ...record, coverageAliases: aliases });
  }
  fs.writeFileSync(newFile, JSON.stringify({
    ...newArtifact,
    checkpoints: merged,
    outcomeContract: {
      schemaVersion: 1,
      journeys: [...outcomeMap.values()]
    }
  }, null, 2));
}

let playwrightCli;
try {
  playwrightCli = require.resolve('@playwright/test/cli');
} catch (_) {
  usage('Playwright is not installed; run npm ci and npm run install-browser first');
}
const playwrightArgs = ['test'];
if (listOnly) playwrightArgs.push('--list');
if (grep) playwrightArgs.push('--grep', grep);
if (grepInvert) playwrightArgs.push('--grep-invert', grepInvert);
const result = spawnSync(process.execPath, [playwrightCli, ...playwrightArgs], {
  cwd: __dirname,
  stdio: 'inherit',
  shell: false,
  env: {
    ...process.env,
    GRIMMORY_COMPAT_RUNTIME: runtime,
    GRIMMORY_COMPAT_OUTPUT: output,
    GRIMMORY_COMPAT_HEADFUL: headful ? '1' : '0',
    GRIMMORY_COMPAT_BOOK_ALIASES: bookAliases.join(','),
    GRIMMORY_KOREADER_OUTPUT: koreaderOutput || ''
  }
});
if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
if (result.status === 0 && mergeCheckpoints) {
  try {
    mergeCheckpointArtifact(
      mergeCheckpoints,
      path.join(output, 'web-reader-checkpoints.json')
    );
  } catch (error) {
    console.error(`run-web-reader: ${error.message}`);
    process.exit(1);
  }
}
process.exit(result.status ?? 1);
