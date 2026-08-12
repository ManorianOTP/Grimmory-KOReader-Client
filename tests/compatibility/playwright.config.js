const path = require('node:path');
const { defineConfig } = require('@playwright/test');

const outputRoot = process.env.GRIMMORY_COMPAT_OUTPUT
  ? path.resolve(process.env.GRIMMORY_COMPAT_OUTPUT)
  : path.resolve(__dirname, '../../build/grimmory-compatibility/browser');

module.exports = defineConfig({
  testDir: __dirname,
  testMatch: /web_reader_journeys\.spec\.js/,
  fullyParallel: false,
  workers: 1,
  timeout: 15 * 60 * 1000,
  expect: { timeout: 20 * 1000 },
  forbidOnly: true,
  retries: 0,
  outputDir: path.join(outputRoot, 'artifacts'),
  reporter: [
    ['line'],
    ['json', { outputFile: path.join(outputRoot, 'results.json') }],
    ['html', { outputFolder: path.join(outputRoot, 'report'), open: 'never' }]
  ],
  use: {
    browserName: 'chromium',
    headless: process.env.GRIMMORY_COMPAT_HEADFUL !== '1',
    locale: 'en-GB',
    timezoneId: 'Etc/UTC',
    viewport: { width: 1440, height: 1000 },
    actionTimeout: 20 * 1000,
    navigationTimeout: 60 * 1000,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    video: 'retain-on-failure'
  }
});
