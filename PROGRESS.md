# Progress

## Current Delivery

The user delegated the remaining implementation after completing the learning
path, and explicitly replaced milestone 5's CLI with a professional graphical
workspace backed by Julia. The original learning log is preserved separately in
[docs/learning-log.md](docs/learning-log.md).

| Milestone | Scope | State |
|---|---|---|
| 0 | Package and hand-calculated reference cases | done |
| 1 | Discrete-event engine | done |
| 2 | Distributions, seeds and repeated estimates | done |
| 3 | Worker/resource capacity, FIFO backpressure and monitoring | done |
| 4 | Failure, timeout, attempt identity, backoff and retries | done |
| 5 | Graphical Studio, configuration and export | done |
| 6 | Capacity sweep and evidence-based recommendation | done |

## Milestone 4

- Finished capped exponential and full-jitter backoff; custom callables remain supported.
- Added RetryReady, attempt outcomes and terminal attempt identity.
- Shared failure/timeout cleanup releases only owned resources and the worker.
- Backoff is worker-free. Retry starts from step one and uses bounded admission.
- Added seeded per-stage failure probability, cancellation and event budgets.
- Preserved legacy deterministic tests and explicit resource configuration.

## Milestone 5

- Local Julia HTTP server with bundled browser assets and an English-only interface.
- Workload editor, reorderable stages, named pools, faults, timeout and retry controls.
- Replicated reports with metadata, queue history, latency histogram and utilization.
- Job filtering/pagination, attempt details, local history and run comparison.
- JSON/TOML configuration round trips; JSON/CSV/PNG result exports.
- Responsive desktop/mobile layout; progress, cancellation and validation.
- Loopback binding, same-origin write checks, request limits and bounded workloads.

## Milestone 6

- Worker/pool capacity grid with identical workload seeds across candidates.
- Per-candidate confidence intervals, heatmap and resource statistics.
- P99/loss targets and capacity cost weights.
- Selection only among tested candidates satisfying upper confidence bounds.
- No recommendation without sufficient replications or successful latency samples.

## Scope Decisions

This release models sequential stages with at most one shared pool per stage.
Workers remain occupied during resource waits. Retry restarts the whole job;
timeout resets at worker start for every attempt. There is no arbitrary code
evaluation in configuration files. This is a local single-user application,
not a public authenticated service.

Recommendations describe this model and finite candidate grid. Confidence
intervals across seeds are not rare-event or production guarantees. Trace
downsampling does not alter exact time-weighted monitoring.

## Verification

Verified on Julia 1.12.7:

- Pkg.test(): 5630/5630 checks passed.
- Playwright/Chromium: 7 end-to-end tests, including English-only UI regression,
  keyboard stage inspection and new-scenario creation.
- Desktop English and mobile 390px/320px layouts checked.
- Canvas pixel checks confirm real, nonblank chart rendering.
- Configuration round trips, exports, history, comparison, capacity application,
  stage/resource editing, cancellation, worker-only and all-failed runs tested.
- HTTP tests reject malformed configuration and cross-origin writes.
- git diff --check passes. Delivery changes are grouped into focused commits.

All milestones are complete within the scope above. Public hosting, arbitrary
workflow graphs, simultaneous multi-pool acquisition and stopping on elapsed
time remain outside this release.

## Interface Refresh

The user's requested redesign removes the Persian interface, language switch,
font assets and localization dependency. The English-only workspace now uses a
compact graphite navigation rail, a right-hand scenario inspector and a revised
analytics layout. Pipeline stages open their editor by mouse or keyboard.
Existing local drafts and reports remain compatible.
