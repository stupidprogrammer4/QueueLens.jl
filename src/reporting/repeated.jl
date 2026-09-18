# Confidence intervals and estimates across repeated runs.

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
    if num_runs == 0
        throw(ArgumentError("Cannot estimate from an empty vector"))
    end
    return Estimate(mean(values), halfwidth, num_runs)
end

"""
    simulate_repeated(scenario, resources, num_runs, capacity = 1;
                      queue_capacity = typemax(Int), warmup_fraction = 0.0) -> RepeatedSummary

Run `scenario` `num_runs` times under different seeds and summarise the spread.
Each run uses the required resource-capacity dictionary to create fresh pools
and queues. Worker capacity is the fourth positional argument and defaults to one.
`queue_capacity` is forwarded to every run. Rejections are reported separately
in `num_rejected` and `rejection_rate`; latency, waiting and throughput estimates
describe only completed jobs. Rejection estimates do not discard warm-up jobs.
Queue and utilization estimates also cover each full run from time zero,
averaging per-run metrics with equal weight rather than pooling run durations.

Run `i` uses seed `scenario.seed + i - 1` with the same workload parameters.
Each simulation constructs its own `Xoshiro` RNG, making the experiment
reproducible from the scenario, resources, run count, capacities and warm-up fraction.

`num_runs` must be at least 2; a single run has no interval to report.

"""
function simulate_repeated(
    scenario::Scenario,
    resources::Dict{Symbol,Int},
    num_runs::Int,
    capacity::Int = 1;
    queue_capacity::Int = typemax(Int),
    warmup_fraction::Float64 = 0.0
)
    if num_runs < 2
        throw(ArgumentError("num_runs must be at least 2, got $num_runs"))
    end
    latency_means = Vector{Float64}()
    latency_p99s = Vector{Float64}()
    waiting_means = Vector{Float64}()
    throughputs = Vector{Float64}()
    rejection_counts = Vector{Float64}()
    rejection_rates = Vector{Float64}()
    queue_means = Float64[]
    worker_utilizations = Float64[]
    resource_queue_means = Dict(name => Float64[] for name in keys(resources))
    resource_utilizations = Dict(name => Float64[] for name in keys(resources))
    for i in 1:num_runs
        run_scenario = Scenario(scenario.arrivals, scenario.service, scenario.num_jobs, scenario.seed + i - 1)
        results = simulate(run_scenario, resources, capacity; queue_capacity)
        summary = summarize(results; warmup_fraction=warmup_fraction)
        push!(latency_means, summary.mean_latency)
        push!(latency_p99s, summary.p99_latency)
        push!(waiting_means, summary.mean_waiting)
        push!(throughputs, summary.throughput)
        push!(rejection_counts, length(results.rejected))
        push!(rejection_rates, rejection_rate(results))
        monitoring = results.monitoring::MonitoringSummary
        push!(queue_means, monitoring.mean_queue_length)
        push!(worker_utilizations, monitoring.worker_utilization)
        for (name, resource) in monitoring.resources
            push!(resource_queue_means[name], resource.mean_queue_length)
            push!(resource_utilizations[name], resource.utilization)
        end
    end
    return RepeatedSummary(
        num_runs,
        warmup_fraction,
        estimate(latency_means),
        estimate(latency_p99s),
        estimate(waiting_means),
        estimate(throughputs),
        estimate(rejection_counts),
        estimate(rejection_rates),
        estimate(queue_means),
        estimate(worker_utilizations),
        Dict(name => estimate(values) for (name, values) in resource_queue_means),
        Dict(name => estimate(values) for (name, values) in resource_utilizations),
    )
end
