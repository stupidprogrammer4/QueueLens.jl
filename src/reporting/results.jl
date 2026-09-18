# Terminal outcomes and immutable reporting containers.

"""
    JobResult(id, arrival_time, start_time, completion_time, waiting_time, latency)

The terminal outcome of one job. Immutable — a completed job is history.

Timing invariants for a completed job:

  - `arrival_time <= start_time <= completion_time`
  - `waiting_time == start_time - arrival_time`
  - `latency == completion_time - arrival_time`
"""
struct JobResult
    id::Int
    arrival_time::Float64
    start_time::Float64
    completion_time::Float64
    waiting_time::Float64
    latency::Float64
end

"""
    JobRejection(id, arrival_time, rejection_time, reason)

Record a job refused before entering the worker queue. Rejections are stored
separately from completed `JobResult`s because no service was performed.
The admission bookkeeping helper currently records `:queue_full` as the reason.
"""
struct JobRejection
    id::Int
    arrival_time::Float64
    rejection_time::Float64
    reason::Symbol
end

"""
    JobFailure(id, arrival_time, start_time, failure_time, step_index, reason)

Terminal failure of a job that had already started service. Separate from both
successful completions and admission rejections. No retry is modeled yet.
The recorded stage is the one executing or waiting for a resource at failure
time. A timeout is represented by `reason = :timeout`, not a separate outcome.
"""
struct JobFailure
    id::Int
    arrival_time::Float64
    start_time::Float64
    failure_time::Float64
    step_index::Int
    reason::Symbol
end

"""
    ResourceSummary(capacity, mean_queue_length, utilization)

Scalar snapshot of one resource's full-run time-weighted metrics. Queue length
counts waiting jobs; utilization is mean occupied slots divided by capacity.
"""
struct ResourceSummary
    capacity::Int
    mean_queue_length::Float64
    utilization::Float64
end

"""
    MonitoringSummary(duration, worker_capacity, mean_queue_length, worker_utilization, resources)

Time-weighted metrics over [0, duration], including initial idle time and the
final draining interval. Utilization is a fraction, not a percentage; workers
remain occupied during resource waits. Zero-duration runs report zero means
and utilization. `resources` maps names to scalar `ResourceSummary` snapshots,
not live pools or accumulators. Completion-based warm-up does not apply here.
"""
struct MonitoringSummary
    duration::Float64
    worker_capacity::Int
    mean_queue_length::Float64
    worker_utilization::Float64
    resources::Dict{Symbol,ResourceSummary}
end

"""
    SimulationResult(completed, rejected, monitoring)
    SimulationResult(completed, rejected)
    SimulationResult(completed, rejected, monitoring, failed)

Outcomes of one finished simulation. `completed` holds `JobResult`s in
completion order; `rejected` holds `JobRejection`s in rejection order.
Each input job has one outcome. Rejected jobs have no service latency and
must not be included in the completed-job latency statistics.
`failed` holds terminal `JobFailure`s separately; omitted failure vectors are
fresh empty vectors. Failed jobs have no successful completion outcome.
Simulation entry points always provide `monitoring::MonitoringSummary`.
Manually assembled outcome-only reports may omit it; `nothing` means unavailable,
not zero utilization. Outcomes alone cannot reconstruct resource histories.
"""
struct SimulationResult
    completed::Vector{JobResult}
    rejected::Vector{JobRejection}
    monitoring::Union{Nothing,MonitoringSummary}
    failed::Vector{JobFailure}
end

# Runs without failure outcomes receive independent empty failure storage.
SimulationResult(completed::Vector{JobResult}, rejected::Vector{JobRejection},
                 monitoring::Union{Nothing,MonitoringSummary}) =
    SimulationResult(completed, rejected, monitoring, JobFailure[])

# Preserve outcome-only construction without inventing missing time histories.
SimulationResult(completed::Vector{JobResult}, rejected::Vector{JobRejection}) =
    SimulationResult(completed, rejected, nothing)

"""
    Summary

Aggregate view of one run's results.

Reports both central tendency and tail, because for a workload with a long
right tail the mean alone misleads in both directions: it sits above what a
typical job experiences, and far below what the slowest ones do.

  - `num_completed`  — results actually summarised, after warm-up discards
  - `num_discarded`  — results dropped as warm-up
  - `throughput`     — completed jobs per unit of simulated time
  - `mean_latency`   — arrival to completion, averaged
  - `p50_latency`, `p95_latency`, `p99_latency` — latency percentiles
  - `mean_waiting`   — arrival to start of service, averaged
"""
struct Summary
    num_completed::Int
    num_discarded::Int
    throughput::Float64
    mean_latency::Float64
    p50_latency::Float64
    p95_latency::Float64
    p99_latency::Float64
    mean_waiting::Float64
end

"""
    Estimate(mean, halfwidth, num_runs)

A measured quantity together with the 95% confidence interval half-width of
its mean, so it reads as `0.546 ± 0.008` rather than as a bare number.

The interval describes uncertainty about the *mean across runs*, and narrows
like `1 / sqrt(num_runs)`. It says nothing about the spread within a run —
that is what the percentiles are for.
"""
struct Estimate
    mean::Float64
    halfwidth::Float64
    num_runs::Int
end

"""
    RepeatedSummary

Results of running one scenario across several seeds. Reports mean latency,
P99 latency, mean waiting time and throughput, each with a confidence interval
for its mean across runs. P50 and P95 remain available in per-run `Summary`.

Records `warmup_fraction` alongside the numbers so the discard is explicit.
`num_rejected` estimates the full-run rejected-job count across seeds, without
the completion-based warm-up discard used for latency and throughput.
`rejection_rate` estimates the full-run fraction of jobs rejected, not a
count per unit time or a percentage.
`mean_queue_length`, `worker_utilization`, `resource_mean_queue_length` and
`resource_utilization` estimate full-run time-weighted metrics across seeds.
Resource dictionaries include unused configured pools with zero estimates.
These metrics are not trimmed by the completion-based warm-up fraction.
"""
struct RepeatedSummary
    num_runs::Int
    warmup_fraction::Float64
    latency_mean::Estimate
    latency_p99::Estimate
    waiting_mean::Estimate
    throughput::Estimate
    num_rejected::Estimate
    rejection_rate::Estimate
    mean_queue_length::Estimate
    worker_utilization::Estimate
    resource_mean_queue_length::Dict{Symbol,Estimate}
    resource_utilization::Dict{Symbol,Estimate}
end
