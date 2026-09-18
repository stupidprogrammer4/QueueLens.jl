# Architecture

QueueLens separates immutable model definitions, mutable simulation state,
statistical reporting, experiment orchestration and browser presentation.

## Ownership

| Directory | Responsibility |
|---|---|
| src/models | Jobs, stages, distributions, events, retry policies and backoff |
| src/simulation | Event calendar, state, scheduling, handlers, ownership and monitoring |
| src/reporting | Result containers, single/repeated statistics and REPL rendering |
| src/experiments | Validated configuration, workload generation, reports and sweeps |
| app/server.jl | Loopback HTTP API, asynchronous jobs, cancellation and static assets |
| app/public | Local browser UI, charts, import/export and IndexedDB history |
| test | Julia unit, contract and integration tests |
| app/tests | Playwright browser and API tests |
| experiments | Earlier standalone learning experiments |

QueueLens.jl defines exports and include order. The package does not start a
server when imported. The server depends on the experiment API, never the other
way around. Browser code does not implement simulation or recommendation logic.

## Event and Ownership Flow

Arrival enters bounded FIFO admission. Starting a job occupies a worker and
schedules its attempt timeout. Each stage optionally acquires one pool, runs,
then releases it to the oldest resource waiter. Stage completion advances the
job; whole-job completion releases the worker.

Failure and timeout validate before shared attempt cleanup. Cleanup records the
attempt, releases held ownership or removes only that job from its resource
queue, frees its worker, and either records terminal failure or schedules
RetryReady. The attempt id increments before backoff so old events immediately
become stale. Ready retries pass through admission again.

The calendar sorts by time, timeout priority, then insertion sequence. Ordinary
events at a deadline precede timeout events. Stale events are filtered before
advancing the clock. No heap deletion is required for cancellation of an attempt.

TimeWeightedStat integrates the previous occupancy over elapsed virtual time.
The engine observes state after each meaningful event. Optional traces store
snapshots with a bounded, deterministically thinned history; integrals do not
depend on these display samples.

## Experiment Layer

Configuration is parsed into ordinary data and validated without eval. Each
replication creates fresh jobs, resources and state. Arrival/stage samples use
the replication seed; engine fault/backoff draws use a separate seed offset.
Stage durations remain attached to a job across retries.

Reports retain normalized configuration, fingerprint and seeds. Capacity sweeps
reuse workload seeds, calculate per-run confidence intervals and select only
tested candidates meeting the requested upper bounds.

## Local Server

HTTP requests submit a run or sweep and poll its id. At most two jobs run
concurrently; the latest eight server jobs are retained. Cooperative Julia tasks
yield every 256 calendar events and between replications, allowing status and
cancellation requests. Cancellation returns no partial report.

The server binds to 127.0.0.1 and checks Host, Origin and a custom write header.
Request bodies are limited to 2 MB. CSP uses bundled scripts, fonts and icons.
There is no authentication: do not expose this server through a public proxy.

Browser IndexedDB retains twelve reports independently from the server's
short-lived job registry. Draft configuration lives in localStorage. Downloaded
JSON is the portable report; browser storage is convenience, not a backup.
