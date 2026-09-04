# Progress

Learning log for QueueLens.jl: what is done, what was decided and why, and what
is still open. Kept per section 14 of the project guide.

## Status

| Milestone | Scope | State |
|---|---|---|
| 0 | Julia foundations, package skeleton, deterministic run | done |
| 1 | Minimal discrete-event engine | done |
| 2 | Probabilistic workloads | done |
| 3 | Shared resource pools and backpressure | not started |
| 4 | Failure, timeout and retry | not started |
| 5 | CLI, configuration and plots | not started |
| 6 | Parameter sweep and recommendation | not started |

Test suite: 1668 passing, 0 failing.

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

## Milestone 2 — done

Done:

- `Constant`, `Exponential`, `LogNormal`, sampled through `sample(rng, d)`
- inner constructors validating distribution parameters
- `Scenario` bundling arrivals, service, job count and seed
- lazy arrival generation: each arrival schedules the next
- `SimState` parameterised on the RNG type, carrying the run's rng and scenario

Also done: `summarize` with percentiles and an optional warm-up discard,
`percentile` by the nearest-rank definition, `sample(rng, d, n)`,
`simulate_repeated` reporting every quantity as `value ± halfwidth` across
seeds.

Definition of done met: the same seed reproduces the same run, distribution
parameters are validated at construction, and results report both central
tendency (mean, P50) and tail (P95, P99) — each with a confidence interval.

### Verified against theory

With arrivals `Exponential(8.0)`, mean service 0.1s (so `rho = 0.8`), holding
the *mean* service time fixed and varying only its variance. Compared against
the Pollaczek-Khinchine formula for M/G/1:

    W = rho * E[S] * (1 + C^2) / (2 * (1 - rho))

Mean waiting time, averaged over 5 seeds at 50,000 jobs each:

| service | `C^2` | W theory | W simulated | gap |
|---|---|---|---|---|
| `Constant(0.1)` | 0 | 0.200 | 0.201 | −0.7% |
| `LogNormal`, sigma 1.0 | 1.72 | 0.544 | 0.546 | −0.4% |

Mean waiting time rises 2.7x, and P99 latency 3.4x, with no change to the mean
service time or the arrival rate. Variance alone drives it. The engine sits on
the analytical result.

### What a single seed cost us

An earlier version of this section reported a consistent 2–4% shortfall against
theory from a **single run at seed 42**, and explained it as the warm-up
transient: a run starts with an empty system, so early jobs barely wait.

That explanation was wrong. Adding a 10% warm-up discard did not close the gap;
it moved the numbers slightly further from theory. A second explanation —
finite-run under-sampling of rare long busy periods — was also wrong: the gap
does not shrink between 50,000 and 2,000,000 jobs.

Averaging over 5 seeds makes it vanish at every run length. There was no bias.
Seed 42 simply landed low, and 1.5% of noise was mistaken for signal, twice.

The lesson is the one milestone 2 is built around: **one run is not a
measurement**. Until `summarize` reports a confidence interval across seeds,
any single number it produces can be read as evidence for a story that is not
there.

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
14. **Percentiles use the nearest-rank definition**, so a reported P99 is a
    latency some job actually experienced rather than an interpolated value.
    At least nine sample-quantile definitions are in common use and they
    disagree on small samples, so the choice is documented rather than assumed.
15. **Confidence intervals use Student-t, not the normal 1.96.** Run counts here
    are small: at 5 runs the correct multiplier is 2.776, so the normal
    approximation would understate the interval by 30% — which is the same
    class of mistake as reporting a single seed. A small t-table is carried in
    the source rather than adding `Distributions.jl`.
16. **`estimate` of a single value returns an `Inf` half-width**, not `0.0`.
    One observation says nothing about spread, and a zero half-width would
    claim perfect certainty.
17. **Seeds for repeated runs are consecutive**, `scenario.seed + i - 1`, so a
    whole experiment is reproducible from one number.
18. **`throughput` is measured from the first retained job's arrival** to the
    last completion, so a warm-up discard does not leave the denominator
    counting time in which the discarded jobs ran.

## Open questions

- **Warm-up period.** `summarize` supports `warmup_fraction`, but there is no
  evidence yet that this workload needs it: at `rho = 0.8` the measured effect
  is smaller than seed-to-seed noise. Section 12 still requires the discard used
  to be documented alongside any result. A workload closer to saturation, where
  the transient is longer, would be the case to test it against.
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
- Predicted that discarding a warm-up would close the gap to theory. It did not;
  the gap was single-seed noise. See "What a single seed cost us".
- Built a text histogram and watched it fail on a heavy tail: scaling the axis
  by `maximum` lets one sample in 100,000 set the scale for all twenty bins, so
  97% of a `LogNormal(sigma = 1.2)` sample lands in the first bar. Fixed by
  labelling every bin with its edges and share, so the numbers carry the story
  the bars cannot.
- Predicted the calendar's high-water mark under lazy generation. Answer: 2 —
  the next arrival plus the in-flight completion — regardless of job count.
