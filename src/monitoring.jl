"""
    TimeWeightedStat()

Accumulator for a nonnegative quantity that stays constant between events,
such as queue length or occupied worker slots. Starts at time zero with value
zero and no accumulated area.

`area` is the integral accumulated through `last_time`. `last_value` is the
value in effect from `last_time` until the next observation. An update must
account for that previous value before replacing it with a new observation.
Simulation state owns separate worker and per-resource queue and occupancy
accumulators sampled after each handled event. Finished runs expose scalar
snapshots in `SimulationResult.monitoring`.
"""
mutable struct TimeWeightedStat
    area::Float64
    last_time::Float64
    last_value::Float64
end

# Every run needs its own accumulator; no elapsed time or occupancy is assumed.
TimeWeightedStat() = TimeWeightedStat(0.0, 0.0, 0.0)


"""
    observe!(stat::TimeWeightedStat, now::Float64, value::Float64) -> Nothing

Accumulate the previous value over the interval from `last_time` to `now`,
then store the new observation. Equal timestamps contribute no area but
replace the value used for the following interval.

Valid observations have finite time and value, nonnegative value, and time
no earlier than the previous observation. Invalid inputs throw `ArgumentError`
before changing the accumulator. Return `nothing` after a valid update.
"""
function observe!(stat::TimeWeightedStat, now::Float64, value::Float64)
    if !isfinite(now) || !isfinite(value)
        throw(ArgumentError("Observation time and value must be finite"))
    end
    if value < 0.0
        throw(ArgumentError("Observation value must be nonnegative"))
    end
    if now < stat.last_time
        throw(ArgumentError("Observation time must not be earlier than previous observation"))
    end
    stat.area += stat.last_value * (now - stat.last_time)
    stat.last_time = now
    stat.last_value = value
    return nothing
end


"""
    time_weighted_mean(stat::TimeWeightedStat) -> Float64

Read the average from time zero through the last observation, without changing
the accumulator. Later elapsed time is not included until recorded by `observe!`.
The zero-duration convention is `0.0`; otherwise divide area by elapsed time.
"""
function time_weighted_mean(stat::TimeWeightedStat)
    mean = 0.0
    if stat.last_time != 0
        mean = stat.area / (stat.last_time - 0.0)
    end
    return mean
end

"""
    utilization(stat::TimeWeightedStat, capacity::Int) -> Float64

Read mean occupied slots as a fraction of a fixed positive capacity, without
changing the accumulator. The history must describe occupancy, not queue length.
Zero elapsed time returns `0.0`; non-positive capacity must throw `ArgumentError`.
The observation window is time zero through the last recorded observation.
"""
function utilization(stat::TimeWeightedStat, capacity::Int)
    if capacity <= 0
        throw(ArgumentError("capacity must be positive"))
    end
    mean = time_weighted_mean(stat)
    u = mean / capacity
    return u
end
