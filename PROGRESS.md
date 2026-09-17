# Progress

Learning log for QueueLens.jl: what is done, what was decided and why, and what
is still open. Kept per section 14 of the project guide.

## Status

| Milestone | Scope | State |
|---|---|---|
| 0 | Julia foundations, package skeleton, deterministic run | done |
| 1 | Minimal discrete-event engine | done |
| 2 | Probabilistic workloads | done |
| 3 | Worker capacity, shared resource pools and backpressure | done |
| 4 | Failure, timeout and retry | not started |
| 5 | CLI, configuration and plots | not started |
| 6 | Parameter sweep and recommendation | not started |

Latest full suite: 4731 passing via `julia --project=. test/runtests.jl`.
The final capacity experiment adds 48 checks against hand-calculated outcomes.
Monitoring report integration adds 245 checks, including direct simulation
outputs, repeated estimates and seeded conservation checks.
All 20 utilization checks pass, including rejection of zero and negative capacity.
State monitoring tests verify zero initialization and independent accumulators
between metrics and between runs.
Observation tests cover integration with the previous value, equal timestamps,
final intervals, validation before mutation and the explicit `nothing` return.
Coverage includes explicit resource configuration, fresh pools per run,
multi-stage resource contention, FIFO wake-up, and the resource-free regressions.
The admission predicate has 58 checks for boundary conditions, negative limits,
and unchanged state. Arrival integration adds 85 checks for bounded waiting,
zero queue capacity, continued lazy arrivals after rejection, and resource waits.
Public admission API tests cover both outcome vectors, queue-limit forwarding,
seeded rejection counts, completion-only summaries, and repeated-run reports.
`Pkg.test()` still reports the pre-existing project/manifest consistency warning;
dependency resolution is outside this API change.

## Learning workflow

The assistant explains the concept, defines a small function contract and gives
a hand-calculation exercise. The learner implements the functions. The assistant
writes and runs tests, reviews the implementation, and explains the results.
The assistant also maintains comments and documentation and proposes small
commits; the learner commits and pushes. Implementation of simulation functions
stays with the learner unless explicitly requested otherwise.
The learner has delegated API wiring, constructors, tests and documentation to
the assistant; simulation and scheduling logic remain learner exercises.
Exercises should describe the need and function contract, not prescribe code
line by line, so the learner can choose the implementation.

## Milestone 3 - done

Milestones 0 through 3 are complete. Milestone 3 was closed on 2026-09-17 after
the capacity-comparison experiment and regression tests passed.

Done:

- Replaced `busy::Bool` with total `capacity` and occupied `in_use` slots.
- Both `simulate` overloads require resource capacities as their second argument
  and accept worker capacity as their third argument, defaulting to one.
- `simulate_repeated(scenario, resources, num_runs, capacity = 1)` forwards
  configuration to every run, preserving the seeds and warm-up behavior.
- `SimState(scenario, resources, capacity = 1, rng = Xoshiro(scenario.seed))`
  creates independent pools and queues through `register_resource!`.
- `SimState` rejects non-positive capacity and initially has no occupied slots.
- Starts occupy one slot; completions release one slot before starting queued work.
- Implemented the standalone `ResourcePool`, positive-capacity validation,
  `try_acquire!(pool)` and `release!(pool)`. All resource contract tests pass.
- Implemented `ServiceStep` with an optional resource name and a validating
  inner constructor. Its 26 checks cover resource names, zero and positive
  durations, and rejection of negative or non-finite durations.
- Extended `Job` with ordered steps and a finite total service time. The
  original scalar-duration constructor creates one resource-free step;
  empty steps have zero total duration. All 27 job-construction checks pass.
- Extended `JobRecord` with steps and `step_index = 1`; 11 additional checks
  cover preserved job data, initial state, empty jobs and legacy jobs.
- Defined `StepCompleted(time, job_id, step_index)`. Calendar tests verify
  mixed-event chronological ordering and insertion-order ties for this event.
- Implemented `start_current_step!` for resource-free and resource-dependent
  stages. Full pools queue jobs without scheduling a completion.
- `StepCompleted` validates the job and stage, releases its resource, wakes the
  first queued job, then advances the completing job. Only whole-job completion
  releases the worker slot.
- Added tests in `test/worker_tests.jl` for hand-calculated timings, FIFO starts,
  out-of-order completions, simultaneous events, zero service time, invalid
  capacity, seeded runs and per-event resource invariants.

The three-job exercise (arrivals 0/1/2, service 3, two workers) now gives start
times 0/1/3, completion times 3/4/6 and waiting times 0/0/1.

Named pools are connected to explicit-job simulation and covered end to end in
`test/resource_api_tests.jl`. Resource configuration is mandatory, including an
explicit `Dict{Symbol,Int}()` when no resources are needed. The caller supplies
capacities, not mutable pools; each run builds its own pools and FIFO queues.
This deliberately replaces the old API rather than keeping compatibility overloads.

Each step requires zero or one shared resource, acquired before its duration
starts and released when it ends. The worker stays occupied through all stages
and resource waits. `waiting_time` still measures only initial worker waiting;
resource waiting is included in latency. `service_time` caches step durations.

Scenario-generated jobs currently have one resource-free stage, so configured
pools are unused on that path. Resource-dependent stages use explicit jobs.
Simultaneous acquisition of multiple resources and holding resources across
steps are deferred. Bounded worker waiting and rejection of arrivals to a full
queue are implemented. Time-weighted queue means and utilization are reported.
The completion scope uses bounded FIFO worker waiting with rejection when full;
zero queue capacity provides immediate rejection when all workers are occupied.
Additional admission policies are deferred, not prerequisites for this milestone.

The admission exercise `can_admit(state, queue_capacity)` is implemented and tested.
It accepts a job when a worker is free or the worker waiting queue has room;
zero allows no waiting and negative limits throw. The assistant has added
`SimState(...; queue_capacity = typemax(Int))`, separate `JobRejection` storage
in `state.rejected`, and `record_rejection!` bookkeeping. Its 61 additional
checks cover queue configuration, independent rejection storage, successful
rejection and nonmutating error paths.

The learner has wired `can_admit` and `record_rejection!` into
`handle!(::JobArrival)`, always scheduling the next arrival afterwards.
The hand-calculated one-worker example with arrivals 0/0.5/1/3.5 and service
time 3 completes jobs 1/2/4 at times 3/6/9 and rejects job 3 at time 1.
Both `simulate` overloads and `simulate_repeated` now forward the
`queue_capacity` keyword (default `typemax(Int)`). Single runs return
`SimulationResult(completed, rejected)` rather than a vector. Existing callers
that inspect completions now use `.completed`; `summarize(result)` delegates
to completed-job statistics, rejecting a report with no completions.
`RepeatedSummary.num_rejected` estimates the full-run count, independent of
the completion-based warm-up fraction. Resource queues remain unbounded.

The learner implemented `rejection_rate(result::SimulationResult)` in
`src/metrics.jl`: rejected / (completed + rejected), or `0.0` for no outcomes,
without mutation. Tests cover empty, all-completed, all-rejected and mixed
reports. The assistant exported it and wired it into single-run display and
`RepeatedSummary.rejection_rate`, using the existing estimate machinery across
seeds. Rejection rates cover the full run independently of warm-up.
Current topic: time-weighted queue length and worker/resource utilization.
The assistant prepared `TimeWeightedStat` in `src/monitoring.jl`, with
`area`, `last_time`, and `last_value`, all initially zero. `SimState` now owns
independent `queue_length_stat` and `worker_busy_stat` accumulators. Both
simulation loops now sample after handling every event, including the final
event. `SimulationResult.monitoring` now exposes scalar snapshots of the metrics.

The learner completed `observe!(stat::TimeWeightedStat, now::Float64,
value::Float64)`: accumulate `last_value * (now - last_time)` before storing
the new observation. Non-finite inputs, negative values and backwards time
throw before mutation; valid updates return `nothing`. Equal timestamps
contribute zero area. All 35 observation checks pass.
The learner completed `time_weighted_mean(stat)`: return zero at zero duration,
otherwise divide area by `last_time`, without mutation. All 11 mean checks pass.
Accumulators currently measure from time zero through `last_time`.

The learner completed `observe_state!(state::SimState)` in `src/engine.jl`.
It records worker queue length and occupied worker count at the current time,
changing only the accumulators and returning `nothing`. All 59 new checks pass,
including equal timestamps, unchanged counts over a final interval, resource
waits distinct from the worker queue, and preserved operational state.
Worker occupancy includes jobs waiting for a resource, not just active stages.

The learner connected sampling after `handle!` in both `simulate` loops.
Event-driven monitoring fixtures cover explicit and lazy arrivals, initial idle
time, queue waits, simultaneous events and zero-duration runs. They retain
state and exercise real handlers. `test/monitoring_report_tests.jl` now also
tests both `simulate` paths directly through their monitoring output.
The learner added `res_queue_stat`, initialized independently by
`register_resource!`, and records each resource's waiting count in
`observe_state!`. Resource-queue monitoring checks pass, covering multiple
names, independence between runs, registration, equal timestamps and contention.
Two jobs sharing a capacity-one DB pool wait a total of 3 job-time units;
with a resource-free tail ending at time 8, the mean DB queue length is 3/8.
The learner added `res_busy_stat` and samples `pool.in_use` in `observe_state!`.
The assistant completed constructor arguments and per-resource accumulator
initialization in `register_resource!`, without changing the sampling logic.
All 34 additional checks pass, including empty queues with occupied pools,
counts greater than one, independent histories, registration error paths and
the idle tail after the DB pool is released. In the example above, DB occupancy
area is 6 over duration 8, distinct from worker occupancy area 11 and DB queue
area 3.

The learner implemented `utilization(stat, capacity)` as time-weighted mean
occupancy divided by capacity, without mutation. All 20 focused checks pass.
The learner corrected the guard to reject both zero and negative capacity before
division, including at zero elapsed time. The assistant added the docstring
and error message, leaving the calculation and guard to the learner.
The assistant connected these helpers to `MonitoringSummary` and per-resource
`ResourceSummary` snapshots, returned as `SimulationResult.monitoring` and
included in its display. Outcome-only reports can still be constructed with
two arguments; their monitoring is explicitly unavailable (`nothing`), not zero.
Both simulation entry points always supply monitoring. The snapshot contains
no live pools or accumulators, and each call owns a fresh resource dictionary.

`simulate_repeated` now estimates worker queue means and utilization, plus
resource queue means and utilization keyed by name. It uses the existing
`estimate` helper, weighting each run equally. All monitoring covers time zero
through the final event; completion-based warm-up affects neither single-run
monitoring nor repeated monitoring estimates. The throughput window is unchanged.
Scenario jobs remain resource-free, so repeated resource metrics are currently
zero; explicit-job simulations exercise shared resources.

Direct report tests cover hand calculations, initial idle time, zero-duration
runs, simultaneous events, bounded admission, multi-slot resources, an unused
pool, resource-free tails, snapshot independence, display and warm-up behavior.
Seeded multi-stage tests check conservation of total queue waiting time and
occupied slot-time against completed jobs and service steps. Repeated estimates
are checked against the individual runs with the specified seeds.

### Final capacity experiment

The learner correctly predicted that adding workers cannot speed up a
capacity-one DB, while doubling DB capacity with two workers halves total time.
The assistant implemented `experiments/capacity_tradeoff.jl` and its regression
tests. Run it with `julia --project=. experiments/capacity_tradeoff.jl`.
Four jobs arrive at zero, each with one three-second DB step; worker queues are
unbounded. There is no randomness and no warm-up discard.

| Case | Workers | DB slots | End time | Mean worker queue | Mean DB queue | Worker utilization | DB utilization |
|---|---|---|---|---|---|---|---|
| A | 2 | 1 | 12 | 0.75 | 0.75 | 0.875 | 1.0 |
| B | 4 | 1 | 12 | 0.0 | 1.5 | 0.625 | 1.0 |
| C | 2 | 2 | 6 | 1.0 | 0.0 | 1.0 | 1.0 |

A and B complete at 3/6/9/12; C completes at 3/3/6/6. Additional workers move
waiting from the worker queue to the DB queue without improving end time.
Workers remain occupied while waiting for DB access, so worker utilization is
not a measure of active DB work alone. Each queue mean uses its own run duration:
C's worker waiting area is 6, smaller than A's 9, despite a larger queue mean
because the duration falls from 12 to 6.

Definition of done met: configurable worker capacity, resource-aware sequential
steps, FIFO resource waiting and release, explicit isolated resource configuration,
bounded worker admission with rejection reporting, full-run time-weighted queue
and utilization reports, repeated estimates, and a verified capacity experiment.
Alternative admission policies, simultaneous multi-resource acquisition and
resource-aware scenario generation remain future extensions. They are not
implemented or required by the closed milestone's scope.

Next milestone: failure, timeout and retry. Begin by defining how an attempt
differs from a logical job and what happens to its held resources on failure.
No milestone-4 logic has been implemented yet.

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
result. That milestone supported one worker. Multiple worker slots were added
in milestone 3; a dedicated recorder remains future work.

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
seeds for mean latency, P99 latency, mean waiting time and throughput.

Definition of done met: the same seed reproduces the same run, distribution
parameters are validated at construction, and results report both central
tendency (mean, P50) and tail (P95, P99). Repeated runs report confidence
intervals for mean latency, P99 latency, mean waiting time and throughput;
P50 and P95 are currently per-run metrics only.

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

The lesson is the one milestone 2 is built around: a single seed does not
quantify uncertainty. `simulate_repeated` now reports confidence intervals
across seeds, helping distinguish sampling variation from a workload effect.

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
11. **The first arrival lands one sampled gap after `t = 0`**, so every gap is
    drawn the same way. A zero gap can place an arrival at zero. Runs built
    from an explicit `Vector{Job}` specify their own arrival times.
12. **Runs stop on job count.** `duration_seconds` from the guide's config
    example is not implemented yet.
13. **Plotting will use Makie.jl**, and will not be a dependency of QueueLens
    itself — the core simulation must run without it.
14. **Percentiles use the nearest-rank definition**, so a reported P99 is a
    latency some job actually experienced rather than an interpolated value.
    At least nine sample-quantile definitions are in common use and they
    disagree on small samples, so the choice is documented rather than assumed.
15. **Confidence intervals use Student-t for 1 through 30 degrees of freedom.** Run counts here
    are small: at 5 runs the correct multiplier is 2.776, so the normal
    approximation would understate the interval by about 29% — which is the same
    class of mistake as reporting a single seed. A small t-table is carried in
    the source rather than adding `Distributions.jl`. Above 30 degrees of
    freedom, the current implementation falls back to the normal value 1.96.
16. **`estimate` of a single value returns an `Inf` half-width**, not `0.0`.
    One observation says nothing about spread, and a zero half-width would
    claim perfect certainty.
17. **Seeds for repeated runs are consecutive**, `scenario.seed + i - 1`, so a
    whole experiment is reproducible from one number.
18. **`throughput` is measured from the first retained job's arrival** to the
    last completion. This excludes time before that arrival; the window can
    still overlap service of discarded jobs when the retained job queued.
19. **Worker capacity is a positional argument to `simulate`**, defaulting to
    one. `Scenario` still contains only workload parameters and the seed.
    `in_use` belongs to mutable state and must stay between zero and capacity.
20. **Starting one job per handler is sufficient for the current model.** Each
    arrival adds one job and each completion releases one slot. Capacity is
    fixed during a run; bulk admissions or capacity changes would need the
    dispatch rule to be revisited.
21. **Resource configuration is explicit and required.** All simulation entry
    points take a `Dict{Symbol,Int}` as their second argument, even if empty.
    Pools and queues are mutable run state and are never supplied or shared by
    the caller. Existing tests and examples follow the new contract.

## Open questions

- **Warm-up period.** `summarize` supports `warmup_fraction`, but there is no
  evidence yet that this workload needs it: at `rho = 0.8` the measured effect
  is smaller than seed-to-seed noise. Section 12 still requires the discard used
  to be documented alongside any result. A workload closer to saturation, where
  the transient is longer, would be the case to test it against.
- **Report metadata.** Summaries and repeated-run intervals are implemented,
  but result objects do not yet carry the scenario, seed and package version.
  Repeated-run intervals for P50 and P95 are not currently reported.
- **Edge cases for later exercises.** `estimate` checks `num_runs == Inf`
  instead of zero for empty input. The text histogram can omit its maximum
  sample because the computed bin index exceeds the last bin. These need
  learner-implemented fixes and focused checks.
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
- Predicted the calendar's high-water mark under lazy generation with one
  worker: at most 2 events, the next arrival and the in-flight completion.
  With multiple workers, the bound is `capacity + 1`, regardless of job count.
- Extended the engine to multiple worker slots and reproduced the two-worker
  hand-calculated table, distinguishing start time from time spent waiting.
