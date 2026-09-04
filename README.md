# QueueLens.jl

A small discrete-event simulator for exploring queueing, backpressure, worker
concurrency, connection pools, retries, and overload in asynchronous services.

> **Status: pre-0.1, under active development.** The engine is being built from
> scratch as a learning project. Nothing here is production-ready yet.

## Problem statement

You describe an async service — arrival bursts, a worker pool, per-worker
concurrency, a database connection pool, timeouts and a retry policy — and
QueueLens simulates it in virtual time and reports throughput, latency
percentiles, utilization, queue growth, retry amplification, and the likely
bottleneck.

Example of the kind of system it targets:

- 1,000 jobs arrive in bursts
- 8 workers consume jobs
- each worker allows 25 concurrent async tasks
- the database pool has 100 connections
- jobs perform HTTP and database I/O
- failed jobs retry with backoff

## Questions it aims to answer

- What happens when arrival rate exceeds service capacity?
- Does more concurrency improve throughput, or just add waiting on the database?
- How large does the queue grow during a burst?
- How much extra load do retries create?
- Which resource saturates first?
- How do fixed, exponential and jittered backoff compare?
- What is the tradeoff between bounded queues, rejection, and latency?
- How sensitive are results to service-time variance?

## The event loop

```mermaid
flowchart TD
    Q["Pop earliest event"] --> T["Advance virtual clock"]
    T --> H["Apply event handler"]
    H --> N["Schedule new events"]
    N --> M["Record metrics"]
    M --> C{"Events remain?"}
    C -->|Yes| Q
    C -->|No| R["Build report"]
```

The simulation advances a **virtual clock**. It never sleeps in real time to
model service duration.

## Getting started

Requires Julia 1.10 or newer (developed on 1.12).

```console
$ git clone <repo-url> QueueLens
$ cd QueueLens
$ julia --project=.
julia> ]            # enter Pkg mode
(QueueLens) pkg> instantiate
(QueueLens) pkg> test
```

To load the package in a REPL session:

```julia
julia> using QueueLens
```

## Correctness requirements

These are invariants the engine must uphold, and what the test suite exists to
protect:

- Virtual time is monotonic.
- Event ordering is deterministic for equal timestamps.
- Every logical job has exactly one terminal outcome.
- Resource usage never exceeds capacity and never goes negative.
- Timed-out attempts cannot later mutate completed state.
- Queue statistics are time-weighted where appropriate.
- Randomness comes from an explicit RNG, never hidden global state.
- Warm-up behavior and discarded samples are documented.
- Configuration, package version and seed accompany every report.

## Roadmap

| Milestone | Scope | Status |
|---|---|---|
| 0 | Julia foundations: package skeleton, deterministic hand-calculated simulation, event-ordering tests | in progress |
| 1 | Minimal discrete-event engine: event calendar, FIFO queue, worker capacity, recorder | planned |
| 2 | Probabilistic workloads: arrival/service distributions, seeds, percentiles, confidence intervals | planned |
| 3 | Shared resource pools and backpressure: DB pool, bounded queues, admission policies, utilization | planned |
| 4 | Failure, timeout and retry: injection, timeout events, backoff policies, retry amplification | planned |
| 5 | CLI, TOML configuration, CSV/JSON summaries and plots | planned |
| 6 | Parameter sweeps and evidence-based bottleneck recommendations | planned |

## Non-goals for v0.1

Real task execution, a production job queue, distributed simulation, Kubernetes
deployment, a web dashboard, packet-level network simulation, reinforcement
learning, and deep-learning dependencies.

## Planned configuration format

Scenarios will be plain TOML (arriving in Milestone 5 — fields land
incrementally with the milestones that need them):

```toml
seed = 42
duration_seconds = 300.0

[arrival]
kind = "poisson"
rate_per_second = 80.0

[service]
kind = "lognormal"
mean_ms = 120.0
sigma = 0.6

[workers]
count = 8
async_tasks_per_worker = 25

[database]
pool_size = 100
hold_mean_ms = 40.0

[queue]
capacity = 5000
overflow = "reject"

[retry]
max_attempts = 3
strategy = "exponential_jitter"
base_delay_ms = 100.0
```

## Repository layout

```text
QueueLens/
├── Project.toml
├── src/
│   └── QueueLens.jl
├── test/
│   └── runtests.jl
└── README.md
```

Files are split only when responsibilities become real. The target layout adds
`events.jl`, `engine.jl`, `resources.jl`, `policies.jl` and `metrics.jl` under
`src/`, plus `scenarios/`, `experiments/`, `docs/` and `benchmarks/`.

## A note on interpretation

A simulation result is not a production guarantee. Every reported number is
conditional on the model, its assumptions, and the seed used to produce it.

## License

Not yet chosen.
