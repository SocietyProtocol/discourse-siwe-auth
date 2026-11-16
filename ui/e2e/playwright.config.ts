import { defineConfig, devices } from '@playwright/test'

// Browser test of the built sign-in bundle against a local Discourse stand-in
// (e2e/discourse-stub.ts). No network: see e2e/README.md.
export default defineConfig({
  testDir: '.',
  outputDir: './test-results',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  timeout: 60_000,
  expect: { timeout: 20_000 },
  reporter: process.env.CI
    ? [
        ['list'],
        ['html', { open: 'never', outputFolder: './playwright-report' }],
      ]
    : [['list']],
  use: {
    ...devices['Desktop Chrome'],
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
})
