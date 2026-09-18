const { defineConfig } = require("@playwright/test");
module.exports = defineConfig({
  testDir: "./tests",
  timeout: 120000,
  expect: { timeout: 90000 },
  workers: 1,
  use: {
    baseURL: process.env.QUEUELENS_URL || "http://127.0.0.1:8787",
    headless: true,
    launchOptions: process.env.QUEUELENS_CHROMIUM
      ? { executablePath: process.env.QUEUELENS_CHROMIUM }
      : {},
  },
});
