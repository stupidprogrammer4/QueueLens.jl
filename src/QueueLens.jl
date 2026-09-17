"""
    QueueLens

Discrete-event queue simulation with worker slots, named resource pools and
seeded workloads. Simulation inputs describe work and resource capacities;
each run owns its mutable state. Completed jobs feed summary statistics.
"""
module QueueLens

# Public API
export Job, JobResult, JobRejection, SimulationResult
export ResourceSummary, MonitoringSummary
export Summary, summarize, rejection_rate
export Estimate, RepeatedSummary, simulate_repeated
export Scenario
export Distribution, Constant, Exponential, LogNormal, sample
export simulate

# Implementation
# Order matters: types must be defined before they are named in another
# type's fields or in a method signature.
include("distributions.jl")
include("scenario.jl")
include("jobs.jl")
include("events.jl")
include("resources.jl")
include("monitoring.jl")
include("state.jl")
include("metrics.jl")
include("engine.jl")

end # module QueueLens
