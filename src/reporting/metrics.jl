# Read-only summaries of one completed run.

using Statistics

"""
    summarize_monitoring(state::SimState) -> MonitoringSummary

Snapshot an already-observed state using the learner's time-weighted mean and
utilization helpers. Called at the end of simulation, after the final sample.
Does not update observations or retain mutable pools, queues or accumulators.
Each call builds a fresh resource dictionary.
"""
function summarize_monitoring(state::SimState)
    resources = Dict{Symbol,ResourceSummary}()
    for (name, pool) in state.resources
        resources[name] = ResourceSummary(
            pool.capacity,
            time_weighted_mean(state.res_queue_stat[name]),
            utilization(state.res_busy_stat[name], pool.capacity),
        )
    end
    return MonitoringSummary(
        state.now, state.capacity,
        time_weighted_mean(state.queue_length_stat),
        utilization(state.worker_busy_stat, state.capacity), resources,
    )
end

"""
    percentile(sorted, q) -> Float64

The `q`-th percentile of an already-sorted vector, by the **nearest-rank**
definition:

    percentile(sorted, q) = sorted[ceil(q * length(sorted))]

There is no single definition of a sample quantile — at least nine are in
common use, and on small samples they disagree. Nearest-rank is chosen here
because it always returns an observed value rather than an interpolated one,
so a reported P99 is a latency some job actually experienced.

Any report quoting a percentile has to say which definition it used, or the
number cannot be reproduced.

`sorted` must be non-empty and sorted ascending; `q` must be in `(0, 1]`.
"""
function percentile(sorted::Vector{Float64}, q::Float64)
    if q <= 0.0 || q > 1.0
        throw(ArgumentError("q must be in (0, 1], got $q"))
    end
    return sorted[ceil(Int, q * length(sorted))]
end

"""
    summarize(results::Vector{JobResult}; warmup_fraction = 0.0) -> Summary

Summarise non-empty results in completion order, optionally discarding an
initial warm-up.

## Warm-up

A run starts empty, which can affect estimates intended to describe steady
state. The size of that effect depends on the workload and run length. In our
milestone-2 experiment, the apparent shortfall against theory was seed-to-seed
variation; discarding a warm-up did not close it. See PROGRESS.md.

`warmup_fraction` must be in `[0, 1)`. It drops
`floor(Int, warmup_fraction * length(results))` results from the front.
`Summary` records the retained and discarded counts.

## Throughput

`throughput` is the retained job count divided by the time from the first
retained job's arrival to the last retained completion. The initial gap before
that arrival is excluded. This window may overlap the service of discarded
jobs when arrivals queue behind earlier work.
"""
function summarize(results::Vector{JobResult}; warmup_fraction::Float64 = 0.0)
    if warmup_fraction < 0.0 || warmup_fraction >= 1.0
        throw(ArgumentError("warmup_fraction must be in [0, 1), got $warmup_fraction"))
    end
    total = length(results)
    num_discarded = floor(Int, warmup_fraction * total)
    retained_results = results[(num_discarded + 1):end]
    num_completed = length(retained_results)
    throughput = num_completed / (retained_results[end].completion_time - retained_results[1].arrival_time)
    mean_latency = mean(r.latency for r in retained_results)
    sorted_latencies = sort([r.latency for r in retained_results])
    p50_latency = percentile(sorted_latencies, 0.50)
    p95_latency = percentile(sorted_latencies, 0.95)
    p99_latency = percentile(sorted_latencies, 0.99)
    mean_waiting = mean(r.waiting_time for r in retained_results)
    return Summary(num_completed, num_discarded, throughput, mean_latency, p50_latency, p95_latency, p99_latency, mean_waiting)
end

"""
    summarize(result::SimulationResult; warmup_fraction = 0.0) -> Summary

Summarise completed jobs only, using the same completion-order warm-up rule
as the vector overload. Rejections remain available in `result.rejected` and
are never interpreted as zero-latency completions or discarded by warm-up.
Throw `ArgumentError` when there are no completed jobs to summarise.
Full-run time-weighted statistics remain in `result.monitoring`, unaffected
by this completion-based warm-up discard.
"""
function summarize(result::SimulationResult; warmup_fraction::Float64 = 0.0)
    if isempty(result.completed)
        throw(ArgumentError("cannot summarize a run with no completed jobs"))
    end
    return summarize(result.completed; warmup_fraction)
end

"""
    rejection_rate(result::SimulationResult) -> Float64

Return rejected jobs divided by all completed, rejected and terminal failed jobs. The result
is a fraction in [0, 1], not a percentage or a count per unit time. An empty
report returns `0.0` by convention. This does not mutate the report and always
uses the full run, independent of completion-based warm-up in `summarize`.
"""
function rejection_rate(result::SimulationResult)
    total_jobs = length(result.completed) + length(result.rejected) + length(result.failed)
    rate = 0.0
    if total_jobs !== 0
        rate = length(result.rejected) / total_jobs
    end
    return rate
end
