const { chromium, expect } = require("@playwright/test");
const { mkdirSync } = require("node:fs");
const { join } = require("node:path");

// Use an isolated browser profile and real reports, never the user's saved runs.
async function main() {
  const output = join(__dirname, "../../docs/images");
  mkdirSync(output, { recursive: true });
  const browser = await chromium.launch(
    process.env.QUEUELENS_CHROMIUM
      ? { executablePath: process.env.QUEUELENS_CHROMIUM }
      : {},
  );
  try {
    const page = await browser.newPage({
      viewport: { width: 1600, height: 1050 },
      deviceScaleFactor: 1,
    });
    await page.goto(process.env.QUEUELENS_URL || "http://127.0.0.1:8787");
    await expect(page.locator("#report-content")).toBeVisible({
      timeout: 90000,
    });
    await expect(page.locator("#run")).toBeEnabled();
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: join(output, "studio-overview.png") });

    await page.locator('[data-view="sweep"]').click();
    await page.locator("#sweep-p99").fill("3");
    await page.locator("#run-sweep").click();
    await expect(page.locator("#sweep-result")).toBeVisible({ timeout: 90000 });
    await expect(page.locator("#run-sweep")).toBeEnabled();
    await expect(page.locator("#error")).toBeHidden();
    await page.screenshot({ path: join(output, "studio-capacity.png") });

    await page.locator("#preset").selectOption("2");
    await page.locator("#run").click();
    await expect(page.locator("#run")).toBeEnabled({ timeout: 90000 });
    await expect(page.locator("#history-count")).toHaveText("3");
    await page.locator('[data-view="compare"]').click();
    await expect(page.locator("#comparison-table th")).toHaveCount(3);
    await page.evaluate(() => new Promise(requestAnimationFrame));
    await page.screenshot({ path: join(output, "studio-comparison.png") });
    console.log("Saved three real Studio screenshots to docs/images.");
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
