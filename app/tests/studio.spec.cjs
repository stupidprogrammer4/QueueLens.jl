const { test, expect } = require("@playwright/test");

test("new scenario and keyboard stage inspection across desktop sizes", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await page.goto("/");
  await expect(page.locator("#report-content")).toBeVisible();
  await expect(page.locator("#run")).toBeEnabled();
  await page.locator("#new-scenario").click();
  await expect(page.locator("#project-name")).toHaveValue("Untitled scenario");
  const stage = page.locator('[data-stage="1"]');
  await stage.focus();
  await stage.press("Enter");
  await expect(page.locator('[data-path="steps.1.name"]')).toBeFocused();
  await expect(page.locator(".step-item.selected")).toHaveCount(1);
  for (const width of [1920, 1024, 820]) {
    await page.setViewportSize({ width, height: 1080 });
    await expect
      .poll(() =>
        page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
      )
      .toBeTruthy();
    const main = await page.locator("#main").boundingBox();
    const editor = await page.locator("#editor").boundingBox();
    expect(main.x + main.width).toBeLessThanOrEqual(editor.x + 1);
  }
});

test("real simulation, editing, exports, history and comparison", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.addInitScript(() => localStorage.setItem("ql-language", "fa"));
  await page.goto("/");
  await expect(page.locator("#report-content")).toBeVisible();
  await expect(page.locator("#run")).toBeEnabled();
  await expect(page.locator("#error")).toBeHidden();
  const png = page.waitForEvent("download");
  await page.locator('[data-chart="trace-chart"]').click();
  expect((await png).suggestedFilename()).toBe("trace-chart.png");
  await expect(page.locator("#jobs-table tbody tr")).toHaveCount(15);
  const canvas = await page.locator("#trace-chart").evaluate((el) => {
    const data = el
      .getContext("2d")
      .getImageData(0, 0, el.width, el.height).data;
    let pixels = 0;
    for (let i = 3; i < data.length; i += 4) if (data[i]) pixels++;
    return { width: el.width, height: el.height, pixels };
  });
  expect(canvas.width).toBeGreaterThan(200);
  expect(canvas.height).toBeGreaterThan(100);
  expect(canvas.pixels).toBeGreaterThan(1000);
  await expect(page.locator("html")).toHaveAttribute("lang", "en");
  await expect(page.locator("html")).toHaveAttribute("dir", "ltr");
  await expect(page.locator("#language")).toHaveCount(0);
  expect(await page.locator("body").innerText()).not.toMatch(/[\u0600-\u06ff]/);
  await page.screenshot({
    path: "test-results/studio-desktop-en.png",
    fullPage: true,
  });
  await page.locator('[data-path="jobs"]').fill("60");
  await page.locator('[data-path="jobs"]').dispatchEvent("change");
  await page.locator('[data-path="replications"]').fill("2");
  await page.locator('[data-path="replications"]').dispatchEvent("change");
  await page.locator("#run").click();
  await expect(page.locator("#run")).toBeEnabled();
  await expect(page.locator("#error")).toBeHidden();
  await expect(page.locator("#history-count")).toHaveText("2");
  await page.locator("#job-search").fill("99999");
  await expect(page.locator("#jobs-table")).toContainText("No matching jobs");
  await page.locator("#job-search").fill("");
  await page.locator("[data-job]").first().click();
  await expect(page.locator("#job-dialog")).toBeVisible();
  await expect(page.locator("#job-detail tbody tr")).not.toHaveCount(0);
  await page.locator("#close-dialog").click();
  const csv = page.waitForEvent("download");
  await page.locator("#export-csv").click();
  expect((await csv).suggestedFilename()).toBe("queuelens-jobs.csv");
  const json = page.waitForEvent("download");
  await page.locator("#export-json").click();
  expect((await json).suggestedFilename()).toMatch(/\.json$/);
  await page.locator('[data-view="compare"]').click();
  await expect(page.locator("#comparison-table th")).toHaveCount(3);
  await page.locator('[data-view="history"]').click();
  await expect(page.locator(".history-row")).toHaveCount(2);
  await page.reload();
  await expect(page.locator("#report-content")).toBeVisible();
  await expect(page.locator("#history-count")).toHaveText("2");
  expect(errors).toEqual([]);
});

test("capacity sweep produces evidence and applies a tested configuration", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.locator("#report-content")).toBeVisible();
  await expect(page.locator("#run")).toBeEnabled();
  await page.locator('[data-path="jobs"]').fill("30");
  await page.locator('[data-path="jobs"]').dispatchEvent("change");
  await page.locator('[data-path="replications"]').fill("2");
  await page.locator('[data-path="replications"]').dispatchEvent("change");
  await page.locator('[data-view="sweep"]').click();
  await page.locator("#sweep-workers").fill("2,4");
  await page.locator("#sweep-capacities").fill("1,2");
  await page.locator("#sweep-p99").fill("100");
  await page.locator("#sweep-loss").fill("100");
  await page.locator("#run-sweep").click();
  await expect(page.locator("#sweep-result")).toBeVisible();
  await expect(page.locator("#run-sweep")).toBeEnabled();
  await expect(page.locator("#error")).toBeHidden();
  await expect(page.locator("#sweep-table tbody tr")).toHaveCount(4);
  await expect(page.locator("#heatmap button")).toHaveCount(4);
  await page.screenshot({
    path: "test-results/studio-sweep.png",
    fullPage: true,
  });
  page.on("dialog", (d) => d.accept());
  await page.locator("#recommendation [data-apply]").click();
  await expect(page.locator("#view-overview")).toBeVisible();
  await expect(page.locator('[data-path="workers"]')).toHaveValue("2");
});

test("mobile layout and configuration import", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await expect(page.locator("#report-content")).toBeVisible();
  await expect(page.locator("#run")).toBeEnabled();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBeTruthy();
  await page.screenshot({
    path: "test-results/studio-mobile.png",
    fullPage: true,
  });
  await page.locator("#editor-toggle").click();
  await expect(page.locator("#editor")).toBeVisible();
  await page.screenshot({ path: "test-results/studio-mobile-editor.png" });
  await page.locator('[data-path="jobs"]').fill("40");
  await page.locator('[data-path="jobs"]').dispatchEvent("change");
  await page.locator("#editor-close").click();
  await expect(page.locator("#editor")).toBeHidden();
  await page.locator('[data-stage="1"]').click();
  await expect(page.locator("#editor")).toBeVisible();
  await expect(page.locator(".step-item.selected")).toHaveCount(1);
  await page.locator("#editor-close").click();
  const config = await page.evaluate(() =>
    JSON.parse(localStorage.getItem("ql-draft")),
  );
  config.name = "Imported scenario";
  page.on("dialog", (d) => d.accept());
  await page.locator("#import-file").setInputFiles({
    name: "scenario.json",
    mimeType: "application/json",
    buffer: Buffer.from(JSON.stringify(config)),
  });
  await expect(page.locator("#project-name")).toHaveValue("Imported scenario");
  await page.locator("#run").click();
  await expect(page.locator("#run")).toBeEnabled();
  await expect(page.locator("#error")).toBeHidden();
  await page.setViewportSize({ width: 320, height: 740 });
  await expect
    .poll(() =>
      page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
    )
    .toBeTruthy();
});

test("stage editing, invalid import and cancellation remain usable", async ({
  page,
  request,
}) => {
  await page.goto("/");
  await expect(page.locator("#report-content")).toBeVisible();
  await expect(page.locator("#run")).toBeEnabled();
  await page.locator('[data-action="add-resource"]').click();
  await page.locator('[data-action="add-step"]').click();
  await expect(page.locator(".step-item")).toHaveCount(4);
  await page
    .locator('[data-path="steps.3.resource"]')
    .selectOption("resource1");
  await page.locator('[data-action="step-up"][data-index="3"]').click();
  await expect(page.locator('[data-path="steps.2.resource"]')).toHaveValue(
    "resource1",
  );
  const original = await page.locator("#project-name").inputValue();
  await page.locator("#import-file").setInputFiles({
    name: "bad.json",
    mimeType: "application/json",
    buffer: Buffer.from('{"jobs":-1}'),
  });
  await expect(page.locator("#error")).toBeVisible();
  await expect(page.locator("#project-name")).toHaveValue(original);
  await page.locator("#dismiss-error").click();
  const config = (await (await request.get("/api/presets")).json())[0];
  config.jobs = 20000;
  config.replications = 5;
  page.on("dialog", (d) => d.accept());
  await page.locator("#import-file").setInputFiles({
    name: "large.json",
    mimeType: "application/json",
    buffer: Buffer.from(JSON.stringify(config)),
  });
  await expect(page.locator('[data-path="jobs"]')).toHaveValue("20000");
  await page.locator('[data-view="sweep"]').click();
  await page.locator("#sweep-workers").fill("2,4,8");
  await page.locator("#sweep-capacities").fill("1,2");
  const submitted = page.waitForResponse(
    (r) => r.url().endsWith("/api/jobs") && r.request().method() === "POST",
  );
  await page.locator("#run-sweep").click();
  const { id } = await (await submitted).json();
  await expect(page.locator("#cancel")).toBeVisible();
  await page.locator("#cancel").click();
  await expect(page.locator("#cancel")).toBeHidden();
  await expect(page.locator("#run")).toBeEnabled();
  await expect(page.locator("#error")).toBeHidden();
  expect((await (await request.get("/api/jobs/" + id)).json()).status).toBe(
    "cancelled",
  );
});

test("HTTP boundaries reject malformed and cross-origin writes", async ({
  request,
}) => {
  const headers = { "X-QueueLens": "studio" };
  const presets = await (await request.get("/api/presets")).json();
  const bad = await request.post("/api/jobs", {
    data: { configuration: { ...presets[0], jobs: -1 } },
    headers,
  });
  expect(bad.status()).toBe(400);
  const cross = await request.post("/api/jobs", {
    data: { configuration: presets[0] },
    headers: { ...headers, Origin: "https://example.com" },
  });
  expect(cross.status()).toBe(403);
  const noHeader = await request.post("/api/jobs", {
    data: { configuration: presets[0] },
  });
  expect(noHeader.status()).toBe(403);
  const missing = await request.get("/api/jobs/unknown");
  expect(missing.status()).toBe(404);
  const toml = await (
    await request.post("/api/config/export", { data: presets[0], headers })
  ).text();
  const roundtrip = await request.post("/api/config/import", {
    data: { format: "toml", text: toml },
    headers,
  });
  expect(roundtrip.ok()).toBeTruthy();
  expect((await roundtrip.json()).jobs).toBe(presets[0].jobs);
});

test("worker-only and all-failed reports render without fabricated latency", async ({
  page,
  request,
}) => {
  await page.goto("/");
  await expect(page.locator("#report-content")).toBeVisible();
  await expect(page.locator("#run")).toBeEnabled();
  const config = (await (await request.get("/api/presets")).json())[0];
  config.jobs = 12;
  config.resources = [];
  config.steps = [
    {
      name: "Compute",
      resource: "",
      kind: "constant",
      mean: 0.1,
      cv: 0,
      failure_probability: 0,
    },
  ];
  config.retry.strategy = "none";
  await page.locator("#import-file").setInputFiles({
    name: "compute.json",
    mimeType: "application/json",
    buffer: Buffer.from(JSON.stringify(config)),
  });
  await expect(page.locator(".step-item")).toHaveCount(1);
  await page.locator("#run").click();
  await expect(page.locator("#run")).toBeEnabled();
  await expect(page.locator("#error")).toBeHidden();
  await expect(page.locator("#jobs-table .completed")).toHaveCount(12);
  config.steps[0].failure_probability = 1;
  await page.locator("#import-file").setInputFiles({
    name: "failure.json",
    mimeType: "application/json",
    buffer: Buffer.from(JSON.stringify(config)),
  });
  await expect(
    page.locator('[data-path="steps.0.failure_probability"]'),
  ).toHaveValue("1");
  await page.locator("#run").click();
  await expect(page.locator("#run")).toBeEnabled();
  await expect(page.locator("#error")).toBeHidden();
  await expect(page.locator("#jobs-table .failed")).toHaveCount(12);
  await expect(page.locator(".metric-value").nth(1)).toContainText("-");
});
