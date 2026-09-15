# Summaries of completed runs and confidence intervals across repeated runs.
# Aggregation reads results without mutating simulation state.

using Statistics

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
    summarize(results; warmup_fraction = 0.0) -> Summary

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
    show(io, ::MIME"text/plain", s::Summary)

Human-readable rendering, used whenever a `Summary` is displayed on its own —
which is what the REPL does when you evaluate one.

Defining this rather than relying on the default keeps the numbers legible:
the default prints every field positionally, so reading it means counting
commas against the struct definition.

"""
function Base.show(io::IO, ::MIME"text/plain", s::Summary)
    println(io, "Summary of $(s.num_completed) jobs:")
    println(io, "  num_completed: ", s.num_completed)
    println(io, "  num_discarded: ", s.num_discarded)
    println(io, "  throughput: ", round(s.throughput, digits=2))
    println(io, "  mean_latency: ", round(s.mean_latency, digits=2))
    println(io, "  p50_latency: ", round(s.p50_latency, digits=2))
    println(io, "  p95_latency: ", round(s.p95_latency, digits=2))
    println(io, "  p99_latency: ", round(s.p99_latency, digits=2))
    println(io, "  mean_waiting: ", round(s.mean_waiting, digits=2))
end

# --------------------------------------------------------------------------
# Repeated runs
#
# Repeated seeds estimate how much reported metrics vary between runs.
# An interval helps distinguish sampling variation from a workload effect.
# --------------------------------------------------------------------------

# Two-sided 95% Student-t critical values by degrees of freedom. Used instead
# of the normal 1.96 because run counts here are small: at 5 runs (4 df) the
# correct multiplier is 2.776, so the normal approximation would understate
# the interval by about 29%.
const T_CRITICAL_95 = Dict(
    1 => 12.706, 2 => 4.303, 3 => 3.182, 4 => 2.776, 5 => 2.571,
    6 => 2.447, 7 => 2.365, 8 => 2.306, 9 => 2.262, 10 => 2.228,
    11 => 2.201, 12 => 2.179, 13 => 2.160, 14 => 2.145, 15 => 2.131,
    16 => 2.120, 17 => 2.110, 18 => 2.101, 19 => 2.093, 20 => 2.086,
    21 => 2.080, 22 => 2.074, 23 => 2.069, 24 => 2.064, 25 => 2.060,
    26 => 2.056, 27 => 2.052, 28 => 2.048, 29 => 2.045, 30 => 2.042,
)

"""
    t_critical_95(df) -> Float64

Two-sided 95% Student-t critical value for `df` degrees of freedom, from
[`T_CRITICAL_95`](@ref) for 1 through 30 degrees of freedom. Above 30, use
the normal approximation 1.96, which gives a slightly narrower interval.
`df` must be positive.
"""
function t_critical_95(df::Int)
    if df <= 0
        throw(ArgumentError("Degrees of freedom must be positive, got $df"))
    end
    result = get(T_CRITICAL_95, df, 1.96)
    return result

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
    estimate(values) -> Estimate

Mean of non-empty `values` with the half-width of its approximate 95%
confidence interval across runs:

    halfwidth = t * s / sqrt(n)

where `s` is the sample standard deviation and `t` comes from
[`t_critical_95`](@ref) at `n - 1` degrees of freedom.

A single value has no degrees of freedom and therefore no interval; return a
half-width of `Inf` rather than pretending to `0.0`, which would claim perfect
certainty from one observation.

"""
function estimate(values::Vector{Float64})
    num_runs = length(values)
    halfwidth = Inf
    if num_runs > 1
        t = t_critical_95(num_runs - 1)
        s = std(values)
        halfwidth = t * s / sqrt(num_runs)
    end
    if num_runs == Inf
        throw(ArgumentError("Cannot estimate from an empty vector"))
    end
    return Estimate(mean(values), halfwidth, num_runs)
end

"""
    show(io, ::MIME"text/plain", e::Estimate)

Render as `value ± halfwidth`.

"""
function Base.show(io::IO, ::MIME"text/plain", e::Estimate)
    println(io, round(e.mean, digits=3), " ± ", round(e.halfwidth, digits=3), " (n = ", e.num_runs, ")")
end

"""
    RepeatedSummary

Results of running one scenario across several seeds. Reports mean latency,
P99 latency, mean waiting time and throughput, each with a confidence interval
for its mean across runs. P50 and P95 remain available in per-run `Summary`.

Records `warmup_fraction` alongside the numbers so the discard is explicit.
"""
struct RepeatedSummary
    num_runs::Int
    warmup_fraction::Float64
    latency_mean::Estimate
    latency_p99::Estimate
    waiting_mean::Estimate
    throughput::Estimate
end

"""
    simulate_repeated(scenario, num_runs; warmup_fraction = 0.0) -> RepeatedSummary

Run `scenario` `num_runs` times under different seeds and summarise the spread.
This helper currently uses the default single-worker capacity; it does not
accept the capacity argument supported by `simulate`.

Run `i` uses seed `scenario.seed + i - 1` with the same workload parameters.
Each simulation constructs its own `Xoshiro` RNG, making the experiment
reproducible from the scenario and run count.

`num_runs` must be at least 2; a single run has no interval to report.

"""
function simulate_repeated(scenario::Scenario, num_runs::Int; warmup_fraction::Float64 = 0.0)
    if num_runs < 2
        throw(ArgumentError("num_runs must be at least 2, got $num_runs"))
    end
    latency_means = Vector{Float64}()
    latency_p99s = Vector{Float64}()
    waiting_means = Vector{Float64}()
    throughputs = Vector{Float64}()
    for i in 1:num_runs
        run_scenario = Scenario(scenario.arrivals, scenario.service, scenario.num_jobs, scenario.seed + i - 1)
        results = simulate(run_scenario)
        summary = summarize(results; warmup_fraction=warmup_fraction)
        push!(latency_means, summary.mean_latency)
        push!(latency_p99s, summary.p99_latency)
        push!(waiting_means, summary.mean_waiting)
        push!(throughputs, summary.throughput)
    end
    return RepeatedSummary(
        num_runs,
        warmup_fraction,
        estimate(latency_means),
        estimate(latency_p99s),
        estimate(waiting_means),
        estimate(throughputs),
    )
end

"""
    show(io, ::MIME"text/plain", r::RepeatedSummary)

Render the run count, warm-up fraction and each `Estimate` using its default
representation, including its mean, half-width and run count.
"""
function Base.show(io::IO, ::MIME"text/plain", r::RepeatedSummary)
    println(io, "RepeatedSummary of $(r.num_runs) runs (warmup_fraction = $(r.warmup_fraction)):")
    println(io, "  latency_mean: ", r.latency_mean)
    println(io, "  latency_p99: ", r.latency_p99)
    println(io, "  waiting_mean: ", r.waiting_mean)
    println(io, "  throughput: ", r.throughput)
end
