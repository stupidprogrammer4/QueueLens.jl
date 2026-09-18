/* QueueLens Studio: local configuration editor and views over real Julia reports. */
"use strict";
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const clone = (value) => structuredClone(value);
const esc = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const icon = (name) => '<i data-lucide="' + name + '"></i>';
const labels = {
  en: {
    workspace: "Workspace / Simulation",
    configuration: "Scenario settings",
    preset: "Template",
    run: "Run simulation",
    cancel: "Cancel",
    overview: "Overview",
    sweep: "Capacity lab",
    history: "Run history",
    compare: "Compare",
    pipeline: "Service pipeline",
    results: "Performance overview",
    engine: "Julia engine",
    ready: "Ready",
    connecting: "Connecting",
    offline: "Disconnected",
    running: "Running",
    cancelled: "Cancelled",
    noResults: "No simulation results yet",
    queueHistory: "System activity",
    latencyDistribution: "Latency distribution",
    firstRun: "Replication 1",
    resourceUsage: "Resource utilization",
    timeWeighted: "Time-weighted · full run",
    jobs: "Job outcomes",
    searchJob: "Job ID",
    all: "All outcomes",
    completed: "Completed",
    failed: "Failed",
    rejected: "Rejected",
    import: "Import configuration",
    saveConfig: "Save configuration",
    exportReport: "Export JSON report",
    exportCSV: "Export outcomes CSV",
    exportPNG: "Download chart PNG",
    workload: "Workload",
    jobCount: "Jobs",
    workers: "Worker slots",
    queueCapacity: "Queue capacity",
    replications: "Replications",
    seed: "Seed",
    warmup: "Warm-up fraction",
    arrival: "Arrivals",
    distribution: "Distribution",
    gap: "Mean gap · s",
    cv: "Coefficient of variation",
    burstSize: "Jobs per burst",
    resources: "Resources",
    resource: "Resource",
    addResource: "Add resource",
    steps: "Service steps",
    addStep: "Add step",
    duration: "Mean time · s",
    fault: "Failure probability",
    noResource: "Worker only",
    resilience: "Timeout & retry",
    timeout: "Attempt timeout · s (0 = off)",
    strategy: "Backoff",
    maxAttempts: "Max attempts",
    baseDelay: "Base delay · s",
    cap: "Delay cap · s",
    none: "Disabled",
    constant: "Constant",
    exponential: "Exponential",
    lognormal: "Log-normal",
    burst: "Burst",
    fixed: "Fixed",
    jitter: "Full jitter",
    unchanged: "Saved",
    modified: "Edited",
    throughput: "Throughput",
    p99: "P99 latency",
    success: "Success rate",
    amplification: "Retry amplification",
    perSecond: "jobs/s",
    confidence: "95% CI",
    noInterval: "Single run · no CI",
    workerQueue: "Worker queue",
    occupied: "Occupied workers",
    latency: "Latency · ms",
    count: "Jobs",
    time: "Time · s",
    meanQueue: "Mean queue",
    initialWaiting: "Initial wait · ms",
    attempts: "Attempts",
    status: "Outcome",
    arrivalTime: "Arrival · s",
    finish: "Finish · s",
    job: "Job",
    reason: "Reason",
    start: "Start · s",
    detail: "Attempt history",
    stage: "Stage",
    capacityLab: "CAPACITY EXPERIMENT",
    runSweep: "Run grid",
    workerCandidates: "Worker candidates",
    capacityCandidates: "Resource capacities",
    p99Target: "P99 target · s",
    lossTarget: "Maximum loss · %",
    workerWeight: "Worker weight",
    resourceWeight: "Resource weight",
    noSweep: "No capacity experiment yet",
    capacityMap: "Capacity map",
    testedConfigurations: "Tested configurations",
    recommended: "Best tested configuration",
    noRecommendation: "No configuration met the targets",
    apply: "Apply configuration",
    feasible: "Within targets",
    outside: "Outside targets",
    score: "Weighted capacity",
    pool: "Pool slots",
    sweepMethod:
      "Recommendation uses the upper 95% confidence bounds for mean per-run P99 and loss. At least two replications are required. Lowest weighted capacity among tested points; not a production guarantee.",
    localHistory: "Saved in this browser",
    noHistory: "No saved runs",
    restore: "Restore scenario",
    open: "Open",
    delete: "Delete",
    comparisonScope: "Per-run means and 95% confidence intervals",
    noCompare: "No runs selected",
    saved: "Saved",
    imported: "Configuration imported",
    confirmReplace: "Replace the edited configuration?",
    confirmDelete: "Delete this saved report?",
    confirmResource: "Remove this resource? Its steps will become worker-only.",
    remove: "Remove",
    up: "Move up",
    down: "Move down",
    compareLimit: "Select up to three runs",
    loadError: "Could not load the studio",
    retry: "Retry",
    elapsed: "Duration",
    baseline: "Baseline",
    scenarioMismatch: "Results from previous configuration",
    loading: "Loading",
    name: "Name",
    capacity: "Capacity",
    emptyFilter: "No matching jobs",
    unavailable: "Unavailable",
    reportSaved: "Report saved",
    inputError: "Review the configuration fields",
    cancelledRun: "Experiment cancelled",
    seconds: "s",
    successful: "Successful jobs",
    move: "Move",
    oldReport: "Historical report",
  },
};
let config,
  presets = [],
  report = null,
  sweep = null,
  history = [],
  selected = new Set(),
  currentView = "overview";
let activeJob = null,
  busy = false,
  page = 0,
  sortKey = "id",
  sortDescending = false,
  changed = false,
  db;
const charts = {};
const t = (key) => labels.en[key] || key;
const format = (n, digits = 2) =>
  n === null || n === undefined || !Number.isFinite(n)
    ? "-"
    : new Intl.NumberFormat("en-US", {
        maximumFractionDigits: digits,
        notation: Math.abs(n) >= 1000000 ? "compact" : "standard",
      }).format(n);
const mean = (metrics, key) => metrics[key]?.mean ?? null;
function icons() {
  lucide.createIcons();
  // Keep existing SVG nodes stable when a field blur happens during a button click.
  $$("svg[data-lucide]").forEach((el) => el.removeAttribute("data-lucide"));
}
function translate() {
  document.documentElement.lang = "en";
  document.documentElement.dir = "ltr";
  $$("[data-view]").forEach((el) => {
    el.title = t(el.dataset.view);
    el.setAttribute("aria-label", t(el.dataset.view));
  });
  $$("[data-i18n]").forEach((el) => (el.textContent = t(el.dataset.i18n)));
  $$("[data-tip]").forEach((el) => {
    el.title = t(el.dataset.tip);
    el.setAttribute("aria-label", t(el.dataset.tip));
  });
  $$("[data-placeholder]").forEach(
    (el) => (el.placeholder = t(el.dataset.placeholder)),
  );
  icons();
}
function toast(message) {
  $("#toast").textContent = message;
  $("#toast").hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => ($("#toast").hidden = true), 3000);
}
function error(message) {
  $("#error span").textContent = message;
  $("#error").hidden = false;
}
async function api(path, data) {
  const response = await fetch(path, {
    method: data === undefined ? "GET" : "POST",
    headers: { "Content-Type": "application/json", "X-QueueLens": "studio" },
    body: data === undefined ? undefined : JSON.stringify(data),
    signal: AbortSignal.timeout(60000),
  });
  const payload = response.headers
    .get("content-type")
    ?.includes("application/json")
    ? await response.json()
    : await response.text();
  if (!response.ok) throw new Error(payload.error || response.statusText);
  return payload;
}
function field(
  label,
  path,
  value,
  min = 0,
  max = 100000,
  step = "any",
  wide = false,
) {
  return (
    '<label class="' +
    (wide ? "wide" : "") +
    '"><span>' +
    t(label) +
    '</span><input data-path="' +
    path +
    '" type="number" value="' +
    esc(value) +
    '" min="' +
    min +
    '" max="' +
    max +
    '" step="' +
    step +
    '" required></label>'
  );
}
function selectField(label, path, value, options, wide = false) {
  return (
    '<label class="' +
    (wide ? "wide" : "") +
    '"><span>' +
    t(label) +
    '</span><select data-path="' +
    path +
    '">' +
    options
      .map(
        (o) =>
          '<option value="' +
          esc(o[0]) +
          '" ' +
          (o[0] === value ? "selected" : "") +
          ">" +
          esc(o[1]) +
          "</option>",
      )
      .join("") +
    "</select></label>"
  );
}
function group(key, title, content, open = true) {
  return (
    '<details data-group="' +
    key +
    '" ' +
    (open ? "open" : "") +
    "><summary>" +
    t(title) +
    icon("chevron-down") +
    "</summary>" +
    content +
    "</details>"
  );
}
function tool(action, i, glyph, label, disabled = false) {
  return (
    '<button type="button" class="icon-button" data-action="' +
    action +
    '" data-index="' +
    i +
    '" title="' +
    t(label) +
    '" aria-label="' +
    t(label) +
    '" ' +
    (disabled ? "disabled" : "") +
    ">" +
    icon(glyph) +
    "</button>"
  );
}
function renderEditor() {
  const opened = new Map(
    $$("#editor details").map((d) => [d.dataset.group, d.open]),
  );
  const kinds = ["constant", "exponential", "lognormal"].map((k) => [k, t(k)]);
  let html = group(
    "workload",
    "workload",
    '<div class="field-grid">' +
      field("jobCount", "jobs", config.jobs, 1, 20000, 1) +
      field("workers", "workers", config.workers, 1, 256, 1) +
      field(
        "queueCapacity",
        "queue_capacity",
        config.queue_capacity,
        0,
        100000,
        1,
      ) +
      field("replications", "replications", config.replications, 1, 20, 1) +
      field("seed", "seed", config.seed, 0, 2000000000, 1) +
      field("warmup", "warmup_fraction", config.warmup_fraction, 0, 0.9, 0.05) +
      "</div>",
  );
  html += group(
    "arrivals",
    "arrival",
    '<div class="field-grid">' +
      selectField(
        "distribution",
        "arrivals.kind",
        config.arrivals.kind,
        [...kinds, ["burst", t("burst")]],
        true,
      ) +
      field("gap", "arrivals.mean", config.arrivals.mean) +
      field(
        config.arrivals.kind === "burst" ? "burstSize" : "cv",
        config.arrivals.kind === "burst"
          ? "arrivals.burst_size"
          : "arrivals.cv",
        config.arrivals.kind === "burst"
          ? config.arrivals.burst_size
          : config.arrivals.cv,
        config.arrivals.kind === "burst" ? 1 : 0,
        config.arrivals.kind === "burst" ? 20000 : 5,
        config.arrivals.kind === "burst" ? 1 : "any",
      ) +
      "</div>",
    false,
  );
  html += group(
    "resources",
    "resources",
    config.resources
      .map(
        (r, i) =>
          '<div class="resource-item"><input data-path="resources.' +
          i +
          '.name" aria-label="' +
          t("name") +
          '" value="' +
          esc(r.name) +
          '" pattern="[a-zA-Z][a-zA-Z0-9_-]{0,31}" required dir="ltr"><input data-path="resources.' +
          i +
          '.capacity" type="number" min="1" max="256" step="1" value="' +
          r.capacity +
          '" aria-label="' +
          t("capacity") +
          '" required>' +
          tool("remove-resource", i, "trash-2", "remove") +
          "</div>",
      )
      .join("") +
      '<button type="button" class="add-button" data-action="add-resource">' +
      icon("plus") +
      t("addResource") +
      "</button>",
  );
  const resourceOptions = [
    ["", t("noResource")],
    ...config.resources.map((r) => [r.name, r.name]),
  ];
  html += group(
    "steps",
    "steps",
    config.steps
      .map(
        (s, i) =>
          '<div class="step-item"><div class="step-head"><span class="step-number">' +
          (i + 1) +
          '</span><input data-path="steps.' +
          i +
          '.name" aria-label="' +
          t("name") +
          '" value="' +
          esc(s.name) +
          '" maxlength="60" required>' +
          tool("step-up", i, "arrow-up", "up", i === 0) +
          tool(
            "step-down",
            i,
            "arrow-down",
            "down",
            i === config.steps.length - 1,
          ) +
          tool("remove-step", i, "x", "remove", config.steps.length === 1) +
          '</div><div class="field-grid">' +
          selectField(
            "resource",
            "steps." + i + ".resource",
            s.resource,
            resourceOptions,
          ) +
          selectField("distribution", "steps." + i + ".kind", s.kind, kinds) +
          field("duration", "steps." + i + ".mean", s.mean) +
          field(
            "fault",
            "steps." + i + ".failure_probability",
            s.failure_probability,
            0,
            1,
            0.01,
          ) +
          (s.kind === "lognormal"
            ? field("cv", "steps." + i + ".cv", s.cv, 0, 5, "any", true)
            : "") +
          "</div></div>",
      )
      .join("") +
      '<button type="button" class="add-button" data-action="add-step">' +
      icon("plus") +
      t("addStep") +
      "</button>",
  );
  html += group(
    "resilience",
    "resilience",
    '<div class="field-grid">' +
      field("timeout", "timeout", config.timeout, 0, 100000, "any", true) +
      selectField(
        "strategy",
        "retry.strategy",
        config.retry.strategy,
        ["none", "fixed", "exponential", "jitter"].map((k) => [k, t(k)]),
        true,
      ) +
      field(
        "maxAttempts",
        "retry.max_attempts",
        config.retry.max_attempts,
        1,
        20,
        1,
      ) +
      field("baseDelay", "retry.base_delay", config.retry.base_delay) +
      field("cap", "retry.cap", config.retry.cap, 0, 100000, "any", true) +
      "</div>",
    false,
  );
  $("#editor-form").innerHTML = html;
  $$("#editor details").forEach((d) => {
    if (opened.has(d.dataset.group)) d.open = opened.get(d.dataset.group);
  });
  $("#project-name").value = config.name;
  $("#sweep-resource").innerHTML = (
    config.resources.length
      ? config.resources.map((r) => "<option>" + esc(r.name) + "</option>")
      : ['<option value="">' + t("noResource") + "</option>"]
  ).join("");
  renderPipeline();
  icons();
}
function renderPipeline() {
  $("#pipeline-meta").textContent =
    config.steps.length + " " + t("steps") + " · " + config.workers + " worker";
  const node = (title, glyph, detail, extra, cls, stage = null) =>
    '<div class="flow-node ' +
    cls +
    '"' +
    (stage === null
      ? ""
      : ' data-stage="' +
        stage +
        '" tabindex="0" role="button" title="Edit ' +
        esc(title) +
        '" aria-label="Edit ' +
        esc(title) +
        '"') +
    '><div class="flow-title">' +
    icon(glyph) +
    "<span>" +
    esc(title) +
    '</span></div><div class="flow-detail"><span>' +
    esc(detail) +
    "</span><span>" +
    esc(extra) +
    "</span></div></div>";
  $("#pipeline").innerHTML =
    node(
      t("arrival"),
      "radio",
      config.jobs + " jobs",
      config.arrivals.kind,
      "source",
    ) +
    icon("chevron-right") +
    config.steps
      .map((s, i) =>
        node(
          s.name,
          s.resource ? "database" : "cpu",
          format(s.mean * 1000, 1) + " ms",
          s.resource || "worker",
          s.resource ? "resource" : "",
          i,
        ),
      )
      .join(icon("chevron-right"));
  $$("#pipeline>svg,#pipeline>i").forEach((el) =>
    el.classList.add("flow-arrow"),
  );
  $("#dirty").textContent = changed ? t("modified") : "";
  $("#run-meta").textContent =
    "seed " + config.seed + " / " + config.replications + " runs";
  if (report)
    $("#report-stamp").textContent =
      JSON.stringify(report.configuration) === JSON.stringify(config)
        ? report.metadata.fingerprint
        : t("scenarioMismatch");
  icons();
}
function markChanged() {
  changed = true;
  renderPipeline();
  try {
    localStorage.setItem("ql-draft", JSON.stringify(config));
  } catch {}
}
function setConfiguration(value) {
  config = clone(value);
  changed = false;
  renderEditor();
  try {
    localStorage.setItem("ql-draft", JSON.stringify(config));
  } catch {}
}
function chart(id, type, data, options = {}) {
  charts[id]?.destroy();
  charts[id] = new Chart($("#" + id), {
    type,
    data,
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      plugins: {
        legend: {
          position: "bottom",
          labels: {
            boxWidth: 8,
            boxHeight: 8,
            usePointStyle: true,
            font: { size: 10 },
            padding: 18,
          },
        },
        tooltip: { padding: 10 },
      },
      scales: {
        x: {
          grid: { display: false },
          ticks: { font: { size: 10 }, maxTicksLimit: 6 },
          border: { display: false },
        },
        y: {
          beginAtZero: true,
          grid: { color: "#e6ecef" },
          ticks: { font: { size: 10 }, maxTicksLimit: 5 },
          border: { display: false },
        },
      },
    },
    ...options,
  });
}
function ciLabel(metric, scale = 1) {
  return !metric
    ? t("unavailable")
    : metric.halfwidth === null
      ? t("noInterval")
      : "± " + format(metric.halfwidth * scale) + " · " + t("confidence");
}
function renderReport() {
  const metrics = report?.metrics;
  const entries = [
    ["throughput", "throughput", 1, t("perSecond"), "activity"],
    ["p99", "p99", 1000, "ms", "timer"],
    ["success", "success_rate", 100, "%", "circle-check"],
    ["amplification", "amplification", 1, "×", "repeat-2"],
  ];
  $("#metrics").innerHTML = entries
    .map(
      ([label, key, scale, unit, glyph]) =>
        '<div class="metric"><div class="metric-label">' +
        icon(glyph) +
        t(label) +
        '</div><div class="metric-value">' +
        (metrics
          ? format(
              mean(metrics, key) === null ? null : mean(metrics, key) * scale,
            )
          : "-") +
        "<small>" +
        unit +
        '</small></div><div class="metric-foot">' +
        (metrics ? ciLabel(metrics[key], scale) : "") +
        "</div></div>",
    )
    .join("");
  $("#empty-results").hidden = !!report;
  $("#report-content").hidden = !report;
  $("#export-json").disabled = !report;
  $("#export-csv").disabled = !report;
  if (!report) {
    icons();
    return;
  }
  renderPipeline();
  Chart.defaults.font.family = "Inter, sans-serif";
  Chart.defaults.color = "#74808e";
  const trace = report.trace;
  chart(
    "trace-chart",
    "line",
    {
      datasets: [
        {
          label: t("workerQueue"),
          data: trace.map((p) => ({ x: p.time, y: p.waiting })),
          borderColor: "#df926f",
          backgroundColor: "#eebc9e20",
          fill: true,
          stepped: "before",
          borderWidth: 1.7,
          pointRadius: 0,
        },
        {
          label: t("occupied"),
          data: trace.map((p) => ({ x: p.time, y: p.busy })),
          borderColor: "#86a859",
          backgroundColor: "#afcc8416",
          fill: true,
          stepped: "before",
          borderWidth: 1.7,
          pointRadius: 0,
        },
      ],
    },
    {
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        parsing: false,
        plugins: {
          legend: {
            position: "bottom",
            labels: { usePointStyle: true, boxWidth: 7, font: { size: 10 } },
          },
        },
        scales: {
          x: {
            type: "linear",
            grid: { display: false },
            ticks: { maxTicksLimit: 6, font: { size: 10 } },
            title: { display: true, text: t("time"), font: { size: 10 } },
          },
          y: {
            beginAtZero: true,
            grid: { color: "#e7edef" },
            ticks: { maxTicksLimit: 5, font: { size: 10 } },
          },
        },
      },
    },
  );
  const completionOrder = new Map(
    report.attempts
      .filter((a) => a.reason === "completed")
      .map((a, i) => [a.job_id, i]),
  );
  let completed = report.jobs
    .filter((r) => r.status === "completed")
    .sort((a, b) => completionOrder.get(a.id) - completionOrder.get(b.id));
  completed = completed.slice(
    Math.floor(completed.length * report.configuration.warmup_fraction),
  );
  const values = completed.map((r) => r.latency * 1000),
    max = Math.max(1, ...values),
    width = max / 18;
  const bins = Array(18).fill(0);
  values.forEach((v) => bins[Math.min(17, Math.floor(v / width))]++);
  chart("latency-chart", "bar", {
    labels: bins.map((_, i) => format(i * width, 0)),
    datasets: [
      {
        label: t("count"),
        data: bins,
        backgroundColor: "#7198eb",
        borderRadius: 2,
        barPercentage: 0.95,
        categoryPercentage: 1,
      },
    ],
  });
  const resources = [
    {
      name: "Workers",
      glyph: "cpu",
      util: metrics.worker_utilization,
      queue: metrics.mean_queue,
      color: "#96b66b",
    },
    ...Object.entries(report.resources).map(([name, r]) => ({
      name,
      glyph: "database",
      util: r.utilization,
      queue: r.mean_queue,
      color: "#7c9be1",
    })),
  ];
  $("#resource-stats").innerHTML = resources
    .map(
      (r) =>
        '<div><div class="resource-stat-title"><span>' +
        icon(r.glyph) +
        esc(r.name) +
        "</span><strong>" +
        format(r.util.mean * 100, 1) +
        '%</strong></div><div class="utilization-bar"><span style="width:' +
        Math.min(100, r.util.mean * 100) +
        "%;background:" +
        r.color +
        '"></span></div><div class="resource-stat-foot"><span>' +
        t("meanQueue") +
        "</span><span>" +
        format(r.queue.mean) +
        "</span></div></div>",
    )
    .join("");
  renderJobs();
  icons();
}
function renderJobs() {
  if (!report) return;
  const search = $("#job-search").value.trim(),
    status = $("#job-status").value;
  const rows = report.jobs.filter(
    (r) =>
      (status === "all" || r.status === status) &&
      String(r.id).includes(search),
  );
  rows.sort(
    (a, b) =>
      ((a[sortKey] ?? -1) - (b[sortKey] ?? -1)) * (sortDescending ? -1 : 1),
  );
  const pages = Math.max(1, Math.ceil(rows.length / 15));
  page = Math.min(page, pages - 1);
  const columns = [
    ["id", "job"],
    ["status", "status"],
    ["arrival", "arrivalTime"],
    ["finish", "finish"],
    ["latency", "latency"],
    ["waiting", "initialWaiting"],
    ["attempts", "attempts"],
  ];
  $("#jobs-table").innerHTML =
    "<thead><tr>" +
    columns
      .map(
        ([key, label]) =>
          "<th>" +
          (key === "status"
            ? t(label)
            : '<button data-sort="' +
              key +
              '">' +
              t(label) +
              (sortKey === key ? " " + (sortDescending ? "↓" : "↑") : "") +
              "</button>") +
          "</th>",
      )
      .join("") +
    "</tr></thead><tbody>" +
    rows
      .slice(page * 15, page * 15 + 15)
      .map(
        (r) =>
          '<tr><td><button class="job-link" data-job="' +
          r.id +
          '">#' +
          r.id +
          '</button></td><td><span class="status-pill ' +
          r.status +
          '">' +
          t(r.status) +
          "</span></td><td>" +
          format(r.arrival, 3) +
          "</td><td>" +
          format(r.finish, 3) +
          "</td><td>" +
          format(r.latency === null ? null : r.latency * 1000) +
          "</td><td>" +
          format(r.waiting === null ? null : r.waiting * 1000) +
          "</td><td>" +
          r.attempts +
          "</td></tr>",
      )
      .join("") +
    (rows.length
      ? ""
      : '<tr><td colspan="7">' + t("emptyFilter") + "</td></tr>") +
    "</tbody>";
  $("#page-label").textContent =
    format(rows.length, 0) +
    " " +
    t("jobs") +
    " · " +
    (page + 1) +
    " / " +
    pages;
  $("#previous-page").disabled = page === 0;
  $("#next-page").disabled = page === pages - 1;
}
function openJob(id) {
  const row = report.jobs.find((r) => r.id === id);
  $("#job-dialog-title").textContent =
    t("job") + " #" + id + " · " + t(row.status);
  const attempts = report.attempts.filter((a) => a.job_id === id);
  $("#job-detail").innerHTML =
    "<h3>" +
    t("detail") +
    "</h3><table><thead><tr>" +
    ["attempts", "stage", "start", "finish", "reason"]
      .map((k) => "<th>" + t(k) + "</th>")
      .join("") +
    "</tr></thead><tbody>" +
    attempts
      .map(
        (a) =>
          "<tr><td>" +
          a.attempt_id +
          "</td><td>" +
          esc(report.configuration.steps[a.step_index - 1]?.name || "-") +
          "</td><td>" +
          format(a.start_time, 3) +
          "</td><td>" +
          format(a.finish_time, 3) +
          "</td><td>" +
          esc(a.reason) +
          "</td></tr>",
      )
      .join("") +
    "</tbody></table>" +
    (row.reason ? '<p class="method-note">' + esc(row.reason) + "</p>" : "");
  $("#job-dialog").showModal();
}
function setView(view) {
  currentView = view;
  $$(".view").forEach((el) => (el.hidden = el.id !== "view-" + view));
  $$("[data-view]").forEach((el) => {
    el.classList.toggle("active", el.dataset.view === view);
    el.setAttribute(
      "aria-current",
      el.dataset.view === view ? "page" : "false",
    );
  });
  if (view === "compare") renderComparison();
  if (view === "history") renderHistory();
  requestAnimationFrame(() => Object.values(charts).forEach((c) => c.resize()));
}
function setBusy(value) {
  busy = value;
  $("#run").disabled = value;
  $("#run-sweep").disabled = value;
  $("#cancel").hidden = !value;
  $("#progress").hidden = !value;
  $("#status").textContent = value ? t("running") : t("ready");
  $("#cancel").disabled = false;
  if (value) {
    $("#progress-fill").style.width = "0%";
    $("#progress-label").textContent = t("running");
  }
}
async function execute(mode = "run") {
  if (busy) return;
  if (!$("#editor-form").reportValidity()) {
    $("#editor").classList.add("open");
    return;
  }
  if (mode === "sweep" && !$("#sweep-form").reportValidity()) return;
  $("#error").hidden = true;
  setBusy(true);
  $("#editor").classList.remove("open");
  const payload = { mode, configuration: clone(config) };
  if (mode === "sweep")
    payload.options = {
      workers: $("#sweep-workers")
        .value.split(",")
        .map((s) => Number(s.trim())),
      capacities: $("#sweep-capacities")
        .value.split(",")
        .map((s) => Number(s.trim())),
      resource: $("#sweep-resource").value,
      p99_target: Number($("#sweep-p99").value),
      max_loss: Number($("#sweep-loss").value) / 100,
      worker_cost: Number($("#sweep-worker-cost").value),
      resource_cost: Number($("#sweep-resource-cost").value),
    };
  try {
    const submitted = await api("/api/jobs", payload);
    activeJob = submitted.id;
    for (;;) {
      await new Promise((resolve) => setTimeout(resolve, 350));
      const job = await api("/api/jobs/" + activeJob);
      $("#progress-fill").style.width =
        (100 * job.done) / Math.max(1, job.total) + "%";
      $("#progress-label").textContent =
        t("running") + " · " + job.done + " / " + job.total;
      if (job.status === "running") continue;
      if (job.status === "cancelled") {
        toast(t("cancelledRun"));
        break;
      }
      if (job.status === "failed") throw new Error(job.error);
      if (mode === "run") {
        report = job.result;
        page = 0;
        renderReport();
        setView("overview");
      } else {
        sweep = job.result;
        renderSweep();
        setView("sweep");
      }
      await saveHistory(mode, job.result);
      break;
    }
  } catch (err) {
    error(err.message);
  } finally {
    activeJob = null;
    setBusy(false);
  }
}
function renderSweep() {
  if (!sweep) return;
  $("#sweep-empty").hidden = true;
  $("#sweep-result").hidden = false;
  const best =
    sweep.recommended_index === null
      ? null
      : sweep.rows[sweep.recommended_index - 1];
  $("#recommendation").innerHTML =
    '<div class="recommendation ' +
    (best ? "" : "warning") +
    '">' +
    icon(best ? "badge-check" : "circle-alert") +
    "<div><h3>" +
    t(best ? "recommended" : "noRecommendation") +
    "</h3><p>" +
    (best
      ? best.workers +
        " worker · " +
        best.capacity +
        " " +
        esc(sweep.resource) +
        " · " +
        t("score") +
        " " +
        format(best.score)
      : t("sweepMethod")) +
    "</p></div>" +
    (best
      ? '<button class="button" data-apply="' +
        (sweep.recommended_index - 1) +
        '">' +
        t("apply") +
        "</button>"
      : "") +
    "</div>";
  const workers = [...new Set(sweep.rows.map((r) => r.workers))],
    caps = [...new Set(sweep.rows.map((r) => r.capacity))];
  const max = Math.max(
    0.001,
    ...sweep.rows.map((r) => mean(r.metrics, "p99") || 0),
  );
  $("#heatmap").innerHTML =
    '<table dir="ltr"><thead><tr><th>workers / ' +
    esc(sweep.resource || "pool") +
    "</th>" +
    caps.map((c) => "<th>" + c + "</th>").join("") +
    "</tr></thead><tbody>" +
    workers
      .map(
        (w) =>
          "<tr><th>" +
          w +
          "</th>" +
          caps
            .map((c) => {
              const i = sweep.rows.findIndex(
                  (r) => r.workers === w && r.capacity === c,
                ),
                r = sweep.rows[i],
                lat = mean(r.metrics, "p99"),
                alpha = lat === null ? 0.12 : 0.12 + 0.5 * (lat / max);
              return (
                '<td><button data-apply="' +
                i +
                '" style="background:' +
                (r.feasible
                  ? "rgba(41,157,119," + alpha + ")"
                  : "rgba(220,135,104," + alpha + ")") +
                '">' +
                format(lat === null ? null : lat * 1000, 1) +
                "<small>" +
                t(r.feasible ? "feasible" : "outside") +
                "</small></button></td>"
              );
            })
            .join("") +
          "</tr>",
      )
      .join("") +
    "</tbody></table>";
  $("#sweep-table").innerHTML =
    "<thead><tr>" +
    ["workers", "pool", "p99", "throughput", "success", "score", "status"]
      .map((k) => "<th>" + t(k) + "</th>")
      .join("") +
    "<th></th></tr></thead><tbody>" +
    sweep.rows
      .map(
        (r, i) =>
          "<tr><td>" +
          r.workers +
          "</td><td>" +
          r.capacity +
          "</td><td>" +
          format(
            mean(r.metrics, "p99") === null
              ? null
              : mean(r.metrics, "p99") * 1000,
          ) +
          " ms</td><td>" +
          format(mean(r.metrics, "throughput")) +
          "</td><td>" +
          format(mean(r.metrics, "success_rate") * 100) +
          "%</td><td>" +
          format(r.score) +
          '</td><td><span class="status-pill ' +
          (r.feasible ? "completed" : "rejected") +
          '">' +
          t(r.feasible ? "feasible" : "outside") +
          '</span></td><td><button class="job-link" data-apply="' +
          i +
          '">' +
          t("apply") +
          "</button></td></tr>",
      )
      .join("") +
    "</tbody>";
  icons();
}
function download(name, body, mime) {
  const url = URL.createObjectURL(new Blob([body], { type: mime })),
    link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function csv(report) {
  const keys = [
    "id",
    "status",
    "arrival",
    "finish",
    "latency",
    "waiting",
    "attempts",
    "reason",
  ];
  const quote = (v) => '"' + String(v ?? "").replaceAll('"', '""') + '"';
  return (
    "\ufeff" +
    [
      keys.join(","),
      ...report.jobs.map((r) => keys.map((k) => quote(r[k])).join(",")),
    ].join("\r\n")
  );
}
async function openDB() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("queuelens-studio", 1);
    request.onupgradeneeded = () =>
      request.result.createObjectStore("reports", { keyPath: "id" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function loadHistory() {
  if (!db) return;
  history = await new Promise((resolve, reject) => {
    const req = db.transaction("reports").objectStore("reports").getAll();
    req.onsuccess = () =>
      resolve(req.result.sort((a, b) => b.savedAt - a.savedAt));
    req.onerror = () => reject(req.error);
  });
  $("#history-count").textContent = history.length;
  renderHistory();
  renderComparison();
}
async function saveHistory(kind, result) {
  if (!db) return;
  const row = {
    id: crypto.randomUUID(),
    savedAt: Date.now(),
    kind,
    report: result,
  };
  try {
    await new Promise((resolve, reject) => {
      const tx = db.transaction("reports", "readwrite");
      tx.objectStore("reports").put(row);
      history.slice(11).forEach((r) => tx.objectStore("reports").delete(r.id));
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
    if (kind === "run" && selected.size < 2) selected.add(row.id);
    await loadHistory();
  } catch (err) {
    error("History: " + err.message);
  }
}
function renderHistory() {
  $("#history-list").innerHTML = history.length
    ? history
        .map(
          (item) =>
            '<div class="history-row">' +
            icon(item.kind === "run" ? "chart-no-axes-combined" : "grid-2x2") +
            '<div class="history-name"><strong>' +
            esc(item.report.configuration.name) +
            "</strong><p>" +
            new Date(item.savedAt).toLocaleString("en-GB") +
            " · seed " +
            item.report.configuration.seed +
            " · " +
            item.report.configuration.replications +
            " runs</p></div>" +
            (item.kind === "run"
              ? '<div class="history-metrics"><span><small>P99</small>' +
                format(
                  mean(item.report.metrics, "p99") === null
                    ? null
                    : mean(item.report.metrics, "p99") * 1000,
                ) +
                " ms</span><span><small>" +
                t("success") +
                "</small>" +
                format(mean(item.report.metrics, "success_rate") * 100) +
                "%</span></div>"
              : "") +
            '<button class="button" data-history="open" data-id="' +
            item.id +
            '">' +
            t("open") +
            '</button><button class="icon-button" data-history="restore" data-id="' +
            item.id +
            '" title="' +
            t("restore") +
            '" aria-label="' +
            t("restore") +
            '">' +
            icon("rotate-ccw") +
            '</button><button class="icon-button" data-history="delete" data-id="' +
            item.id +
            '" title="' +
            t("delete") +
            '" aria-label="' +
            t("delete") +
            '">' +
            icon("trash-2") +
            "</button></div>",
        )
        .join("")
    : '<div class="empty-state">' +
      icon("history") +
      "<h3>" +
      t("noHistory") +
      "</h3></div>";
  icons();
}
function renderComparison() {
  const runs = history.filter((r) => r.kind === "run");
  $("#comparison-options").innerHTML = runs
    .map(
      (r) =>
        '<label><input type="checkbox" data-compare="' +
        r.id +
        '" ' +
        (selected.has(r.id) ? "checked" : "") +
        ">" +
        esc(r.report.configuration.name) +
        " · " +
        new Date(r.savedAt).toLocaleTimeString("en-GB") +
        "</label>",
    )
    .join("");
  const chosen = runs.filter((r) => selected.has(r.id)).slice(0, 3);
  if (!chosen.length) {
    $("#comparison-table").innerHTML =
      '<div class="empty-state">' + t("noCompare") + "</div>";
    charts["compare-chart"]?.destroy();
    delete charts["compare-chart"];
    return;
  }
  const columns = [
    ["p99", "p99", 1000, "ms"],
    ["throughput", "throughput", 1, "job/s"],
    ["success", "success_rate", 100, "%"],
    ["amplification", "amplification", 1, "×"],
    ["elapsed", "duration", 1, "s"],
  ];
  $("#comparison-table").innerHTML =
    "<table><thead><tr><th></th>" +
    chosen
      .map(
        (r) =>
          "<th>" +
          esc(r.report.configuration.name) +
          "<br>seed " +
          r.report.configuration.seed +
          "</th>",
      )
      .join("") +
    "</tr></thead><tbody>" +
    columns
      .map(
        ([label, key, scale, unit]) =>
          "<tr><td>" +
          t(label) +
          "</td>" +
          chosen
            .map(
              (r) =>
                "<td>" +
                format(
                  mean(r.report.metrics, key) === null
                    ? null
                    : mean(r.report.metrics, key) * scale,
                ) +
                " " +
                unit +
                '<br><span class="subtle">' +
                ciLabel(r.report.metrics[key], scale) +
                "</span></td>",
            )
            .join("") +
          "</tr>",
      )
      .join("") +
    "</tbody></table>";
  chart("compare-chart", "bar", {
    labels: chosen.map((r) => r.report.configuration.name),
    datasets: [
      {
        label: "P50 · ms",
        data: chosen.map((r) =>
          mean(r.report.metrics, "p50") === null
            ? null
            : mean(r.report.metrics, "p50") * 1000,
        ),
        backgroundColor: "#99caba",
      },
      {
        label: "P95 · ms",
        data: chosen.map((r) =>
          mean(r.report.metrics, "p95") === null
            ? null
            : mean(r.report.metrics, "p95") * 1000,
        ),
        backgroundColor: "#739acc",
      },
      {
        label: "P99 · ms",
        data: chosen.map((r) =>
          mean(r.report.metrics, "p99") === null
            ? null
            : mean(r.report.metrics, "p99") * 1000,
        ),
        backgroundColor: "#d8947a",
      },
    ],
  });
}
$("#editor-form").addEventListener("change", (event) => {
  const el = event.target;
  if (!el.dataset.path) return;
  const path = el.dataset.path.split(".");
  let obj = config;
  path.slice(0, -1).forEach((k) => (obj = obj[k]));
  const key = path.at(-1),
    old = obj[key];
  obj[key] = el.type === "number" ? Number(el.value) : el.value;
  if (path[0] === "resources" && key === "name")
    config.steps.forEach((s) => {
      if (s.resource === old) s.resource = obj[key];
    });
  markChanged();
  if (el.tagName === "SELECT" || (path[0] === "resources" && key === "name"))
    renderEditor();
});
$("#editor-form").addEventListener("click", (event) => {
  const b = event.target.closest("[data-action]");
  if (!b) return;
  const i = Number(b.dataset.index),
    action = b.dataset.action;
  if (action === "add-step" && config.steps.length < 12)
    config.steps.push({
      name: "Step " + (config.steps.length + 1),
      resource: "",
      kind: "constant",
      mean: 0.1,
      cv: 0.5,
      failure_probability: 0,
    });
  if (action === "remove-step" && config.steps.length > 1)
    config.steps.splice(i, 1);
  if (action === "step-up" && i > 0)
    [config.steps[i - 1], config.steps[i]] = [
      config.steps[i],
      config.steps[i - 1],
    ];
  if (action === "step-down" && i < config.steps.length - 1)
    [config.steps[i + 1], config.steps[i]] = [
      config.steps[i],
      config.steps[i + 1],
    ];
  if (action === "add-resource" && config.resources.length < 12) {
    let n = 1;
    while (config.resources.some((r) => r.name === "resource" + n)) n++;
    config.resources.push({ name: "resource" + n, capacity: 1 });
  }
  if (action === "remove-resource") {
    if (
      config.steps.some((s) => s.resource === config.resources[i].name) &&
      !confirm(t("confirmResource"))
    )
      return;
    config.steps.forEach((s) => {
      if (s.resource === config.resources[i].name) s.resource = "";
    });
    config.resources.splice(i, 1);
  }
  markChanged();
  renderEditor();
});
$("#project-name").addEventListener("change", (e) => {
  config.name = e.target.value;
  markChanged();
});
$("#preset").addEventListener("change", (e) => {
  if (changed && !confirm(t("confirmReplace"))) return;
  setConfiguration(presets[Number(e.target.value)]);
});
$$("[data-view]").forEach((b) =>
  b.addEventListener("click", () => setView(b.dataset.view)),
);
$("#run").addEventListener("click", () => execute());
$("#run-sweep").addEventListener("click", () => execute("sweep"));
$("#cancel").addEventListener("click", async () => {
  if (!activeJob) return;
  $("#cancel").disabled = true;
  try {
    await api("/api/jobs/" + activeJob + "/cancel", {});
  } catch (e) {
    error(e.message);
    $("#cancel").disabled = false;
  }
});
$("#editor-toggle").addEventListener("click", () =>
  $("#editor").classList.toggle("open"),
);
$("#editor-close").addEventListener("click", () =>
  $("#editor").classList.remove("open"),
);
$("#editor-form").addEventListener("submit", (event) => {
  event.preventDefault();
  execute();
});
$("#sweep-form").addEventListener("submit", (event) => {
  event.preventDefault();
  execute("sweep");
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    $("#editor").classList.remove("open");
    $("#save-options").hidden = true;
  }
});
$("#dismiss-error").addEventListener(
  "click",
  () => ($("#error").hidden = true),
);
$("#new-scenario").addEventListener("click", () => {
  if (changed && !confirm(t("confirmReplace"))) return;
  const fresh = clone(presets[0]);
  fresh.name = "Untitled scenario";
  setConfiguration(fresh);
  setView("overview");
  $("#project-name").focus();
  $("#project-name").select();
});
function inspectStage(element) {
  const index = Number(element.dataset.stage);
  $("#editor").classList.add("open");
  $('#editor details[data-group="steps"]').open = true;
  $$(".step-item").forEach((item, i) =>
    item.classList.toggle("selected", i === index),
  );
  const field = $('[data-path="steps.' + index + '.name"]');
  field.scrollIntoView({ block: "center", behavior: "instant" });
  field.focus({ preventScroll: true });
}
$("#pipeline").addEventListener("click", (event) => {
  const stage = event.target.closest("[data-stage]");
  if (stage) inspectStage(stage);
});
$("#pipeline").addEventListener("keydown", (event) => {
  const stage = event.target.closest("[data-stage]");
  if (stage && (event.key === "Enter" || event.key === " ")) {
    event.preventDefault();
    inspectStage(stage);
  }
});
$("#save-menu").addEventListener(
  "click",
  () => ($("#save-options").hidden = !$("#save-options").hidden),
);
$$("[data-save]").forEach((button) =>
  button.addEventListener("click", async () => {
    try {
      const format = button.dataset.save;
      download(
        "queuelens-scenario." + format,
        format === "toml"
          ? await api("/api/config/export", config)
          : JSON.stringify(config, null, 2),
        format === "toml" ? "application/toml" : "application/json",
      );
      changed = false;
      renderPipeline();
      $("#save-options").hidden = true;
    } catch (e) {
      error(e.message);
    }
  }),
);
$("#import").addEventListener("click", () => $("#import-file").click());
$("#import-file").addEventListener("change", async (e) => {
  const file = e.target.files[0];
  if (!file) return;
  try {
    if (file.size > 2000000) throw new Error("Configuration exceeds 2 MB");
    const data = await api("/api/config/import", {
      format: file.name.endsWith(".toml") ? "toml" : "json",
      text: await file.text(),
    });
    if (changed && !confirm(t("confirmReplace"))) return;
    setConfiguration(data);
    toast(t("imported"));
  } catch (err) {
    error(err.message);
  } finally {
    e.target.value = "";
  }
});
$("#export-json").addEventListener("click", () =>
  download(
    "queuelens-" + report.metadata.fingerprint + ".json",
    JSON.stringify(report, null, 2),
    "application/json",
  ),
);
$("#export-csv").addEventListener("click", () =>
  download("queuelens-jobs.csv", csv(report), "text/csv;charset=utf-8"),
);
$("#export-sweep").addEventListener("click", () =>
  download(
    "queuelens-capacity.json",
    JSON.stringify(sweep, null, 2),
    "application/json",
  ),
);
$$("[data-chart]").forEach((b) =>
  b.addEventListener("click", () => {
    const link = document.createElement("a");
    link.href = $("#" + b.dataset.chart).toDataURL("image/png");
    link.download = b.dataset.chart + ".png";
    link.click();
  }),
);
$("#job-search").addEventListener("input", () => {
  page = 0;
  renderJobs();
});
$("#job-status").addEventListener("change", () => {
  page = 0;
  renderJobs();
});
$("#previous-page").addEventListener("click", () => {
  page--;
  renderJobs();
});
$("#next-page").addEventListener("click", () => {
  page++;
  renderJobs();
});
$("#jobs-table").addEventListener("click", (event) => {
  const job = event.target.closest("[data-job]"),
    sort = event.target.closest("[data-sort]");
  if (job) openJob(Number(job.dataset.job));
  if (sort) {
    sortDescending = sortKey === sort.dataset.sort ? !sortDescending : false;
    sortKey = sort.dataset.sort;
    renderJobs();
  }
});
$("#close-dialog").addEventListener("click", () => $("#job-dialog").close());
$("#view-sweep").addEventListener("click", (event) => {
  const button = event.target.closest("[data-apply]");
  if (!button) return;
  if (changed && !confirm(t("confirmReplace"))) return;
  setConfiguration(sweep.rows[Number(button.dataset.apply)].configuration);
  setView("overview");
  toast(t("apply"));
});
$("#history-list").addEventListener("click", async (event) => {
  const button = event.target.closest("[data-history]");
  if (!button) return;
  const item = history.find((r) => r.id === button.dataset.id);
  if (button.dataset.history === "open") {
    if (item.kind === "run") {
      report = item.report;
      page = 0;
      renderReport();
      setView("overview");
    } else {
      sweep = item.report;
      renderSweep();
      setView("sweep");
    }
  }
  if (button.dataset.history === "restore") {
    if (changed && !confirm(t("confirmReplace"))) return;
    setConfiguration(item.report.configuration);
    setView("overview");
  }
  if (button.dataset.history === "delete" && confirm(t("confirmDelete"))) {
    await new Promise((resolve) => {
      const tx = db.transaction("reports", "readwrite");
      tx.objectStore("reports").delete(item.id);
      tx.oncomplete = resolve;
    });
    selected.delete(item.id);
    await loadHistory();
  }
});
$("#comparison-options").addEventListener("change", (event) => {
  const id = event.target.dataset.compare;
  if (!id) return;
  if (event.target.checked) {
    if (selected.size >= 3) {
      event.target.checked = false;
      toast(t("compareLimit"));
      return;
    }
    selected.add(id);
  } else selected.delete(id);
  renderComparison();
});
async function initialize() {
  translate();
  renderReport();
  $("#connection").textContent = t("connecting");
  try {
    const health = await api("/api/health");
    $("#connection").textContent = "Julia " + health.julia;
    $("#engine-version").textContent = "v" + health.version;
    presets = await api("/api/presets");
    $("#preset").innerHTML = presets
      .map((p, i) => '<option value="' + i + '">' + esc(p.name) + "</option>")
      .join("");
    let draft;
    try {
      draft = JSON.parse(localStorage.getItem("ql-draft"));
    } catch {}
    if (draft) {
      try {
        draft = await api("/api/config/import", {
          format: "json",
          text: JSON.stringify(draft),
        });
      } catch {
        draft = null;
      }
    }
    setConfiguration(draft || presets[0]);
    try {
      db = await openDB();
      await loadHistory();
    } catch (e) {
      error("History: " + e.message);
    }
    const latest = history.find((r) => r.kind === "run");
    if (latest) {
      report = latest.report;
      renderReport();
    } else await execute();
  } catch (e) {
    $("#connection").textContent = t("offline");
    error(t("loadError") + ": " + e.message);
    $("#run").disabled = true;
    $("#run-sweep").disabled = true;
  }
}
initialize();
