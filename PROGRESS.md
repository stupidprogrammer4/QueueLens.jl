# Progress

Learning log for QueueLens.jl: what is done, what was decided and why, and what
is still open. Kept per section 14 of the project guide.

## Status

| Milestone | Scope | State |
|---|---|---|
| 0 | Julia foundations, package skeleton, deterministic run | done |
| 1 | Minimal discrete-event engine | done |
| 2 | Probabilistic workloads | in progress |
| 3 | Shared resource pools and backpressure | not started |
| 4 | Failure, timeout and retry | not started |
| 5 | CLI, configuration and plots | not started |
| 6 | Parameter sweep and recommendation | not started |

Test suite: 1609 passing, 0 failing.

## Milestone 0 — done

Package skeleton, `Project.toml` environment, `Test` wired up as a test target.

Hand-calculated the reference case on paper before writing any code: three jobs
arriving at 0, 1, 2 with a service time of 3 on one FIFO worker, giving waiting
times 0, 2, 4. Implemented `process_jobs` as a single closed-form pass to
reproduce exactly that table.

Definition of done met: virtual clock, identical results across runs, no
plotting or config parser.

## Milestone 1 — done

Replaced the closed-form pass with a real discrete-event engine. The closed-form
version only works for one worker with FIFO order and a known service time; it
cannot express a second worker, a resource pool, or a retry that re-enters the
system mid-run.

Built:

- `SimEvent` with `JobArrival` and `ServiceCompleted`
- an event calendar (`schedule!` / `pop_next!`) over a binary min-heap
- `SimState`, `handle!` dispatched on event type, `start_next_job!`
- `simulate(::Vector{Job})`

Definition of done met: the hand-calculated table still passes unchanged, equal
timestamps resolve deterministically, and a completed job cannot get a second
result.

The milestone-0 tests became the regression net for the rewrite. That was the
first concrete payoff from having written them.

## Milestone 2 — in progress

Done:

- `Constant`, `Exponential`, `LogNormal`, sampled through `sample(rng, d)`
- inner constructors validating distribution parameters
- `Scenario` bundling arrivals, service, job count and seed
- lazy arrival generation: each arrival schedules the next
- `SimState` parameterised on the RNG type, carrying the run's rng and scenario

Not done yet: warm-up handling, `summarize` with percentiles and confidence
intervals, repeated runs across seeds.

### Verified against theory

With arrivals `Exponential(8.0)`, mean service 0.1s (so `rho = 0.8`) and 50,000
jobs, holding the *mean* service time fixed and varying only its variance:

| service | `C^2` | mean wait (P–K) | mean wait (simulated) | P99 latency |
|---|---|---|---|---|
| `Constant(0.1)` | 0 | 0.200 | 0.197 | 1.122 |
| `LogNormal`, sigma 0.6 | 0.43 | 0.287 | 0.268 | 1.527 |
| `LogNormal`, sigma 1.0 | 1.72 | 0.544 | 0.527 | 3.816 |

Compared against the Pollaczek–Khinchine formula for M/G/1:

    W = rho * E[S] * (1 + C^2) / (2 * (1 - rho))

Mean waiting time rises 2.7x and P99 latency 3.4x with no change to the mean
service time or the arrival rate. Variance alone drives it.

Note the simulated figures sit consistently *below* theory, by 2–4%. That is not
sampling noise — it is directional, and it is the warm-up transient: the run
starts with an empty system, so early jobs barely wait and drag the average
down. See the open questions.

## Decisions

Ordered roughly as they were made. Each is a real fork where the alternative was
considered.

1. **`test/`, not `tests/`.** Julia's `Pkg.test()` only looks at `test/runtests.jl`.
2. **`Manifest.toml` is committed**, against the usual convention for a library.
   QueueLens is an experiment tool and section 12 requires results to be
   reproducible, which means pinning exact dependency versions.
3. **`service_time` lives on `Job`**, not as a parameter of the run. Milestone 2
   draws it per job from a distribution; a single run-wide service time is just
   the degenerate case.
4. **Event calendar is a binary min-heap from `DataStructures.jl`**, not a BST
   and not a hand-rolled heap. The calendar needs only `{insert, extract-min}`,
   which is a priority queue, not an ordered set. A BST would add pointer
   chasing and one allocation per node for operations never used.
5. **Ties broken by insertion order via `CalendarEntry`.** A heap is not a stable
   sort, so equal timestamps could otherwise come out in either order and two
   runs could diverge. Each entry carries a monotonic `sequence` and `isless`
   compares `(time, sequence)`. The sequence lives on the wrapper rather than on
   events, so new event types get it for free.
6. **`schedule!` throws on a past or infinite timestamp.** Both can only mean a
   bug upstream, and an event silently parked at infinity would produce a report
   that looks complete but is not.
7. **`JobRecord` holds in-flight bookkeeping** in one mutable struct keyed by job
   id, rather than several parallel dictionaries. Milestone 4 adds attempt and
   timeout state to the same place.
8. **`waiting` is a plain `Vector{Int}`, not a `Queue`.** Julia's arrays keep a
   gap at the front, so `popfirst!` is O(1) amortised — unlike C++'s
   `std::vector`. Measured: draining 2M elements took 2.9ms with one allocation
   for `Vector`, versus 241ms and 2M allocations for `DataStructures.Queue`.
9. **`LogNormal` is parameterised by `mu`, the log-space parameter**, not by the
   mean. So `mu` may legitimately be negative and only `sigma` is validated. A
   scenario file specifying a real-world mean must invert
   `E[X] = exp(mu + sigma^2/2)`; using `mu = log(mean)` overstates the mean by
   about 20% at `sigma = 0.6`, quietly.
10. **The RNG is explicit and lives on `SimState`**, which is parameterised on
    the RNG type so `rng` stays concrete in the hot loop. Bare `rand()` appears
    nowhere in the package.
11. **The first arrival lands one gap after `t = 0`**, not at `t = 0`, so every
    gap is drawn the same way. Runs built from an explicit `Vector{Job}` are
    still free to place a job at zero.
12. **Runs stop on job count.** `duration_seconds` from the guide's config
    example is not implemented yet.
13. **Plotting will use Makie.jl**, and will not be a dependency of QueueLens
    itself — the core simulation must run without it.

## Open questions

- **Warm-up period.** Runs start with an empty system, which biases mean waiting
  time downward by a few percent against M/G/1 theory. How many samples should be
  discarded, and how should that be chosen and documented? Section 12 requires it
  to be documented either way.
- **Reporting.** `summarize(results)` with P50/P95/P99 and confidence intervals
  across repeated seeds is still missing. Percentiles matter more than the mean
  here: for a lognormal service time, about 62% of jobs finish faster than the
  mean, so quoting the mean misleads in both directions.
- **Stopping on elapsed time** as an alternative to job count.
- **`CalendarEntry.event` is an abstract field** and therefore boxed. Inherent to
  a calendar holding mixed event types. Deferred until profiling says it matters;
  section 13 says correctness first.
- **Instrumentation.** `clock_log` and `max_calendar_size` on `SimState` exist
  only so tests can observe invariants. A proper `Recorder` should replace both.

## Exercises completed

- Hand-calculated the three-job FIFO table (arrivals 0/1/2, service 3) and
  derived that waiting grows by 2 per job because `rho = 3`.
- Hand-calculated a per-job service time table (services 3, 1, 4) — now a test.
- Derived `F^-1(u) = -log(1 - u) / rate` for the exponential by inverting its
  CDF, and connected it to `randexp(rng) / rate`.
- Predicted the effect of service-time variance at fixed mean, then measured it.
  Verified against Pollaczek–Khinchine.
- Predicted the calendar's high-water mark under lazy generation. Answer: 2 —
  the next arrival plus the in-flight completion — regardless of job count.
