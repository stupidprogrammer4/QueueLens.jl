"""
    QueueLens

Discrete-event queue simulation with worker slots, named resource pools and
seeded workloads. Simulation inputs describe work and resource capacities;
each run owns its mutable state. Completed jobs feed summary statistics.
"""
module QueueLens

# Public API
export Job, JobResult, JobRejection, JobFailure, SimulationResult
export ResourceSummary, MonitoringSummary
export Summary, summarize, rejection_rate
export Estimate, RepeatedSummary, simulate_repeated
export Scenario
export Distribution, Constant, Exponential, LogNormal, sample
export simulate
export ServiceStep, RetryPolicy, FixedBackoff, ExponentialBackoff, FullJitterBackoff
export retry_delay, AttemptResult

# Workload definitions.
include("models/distributions.jl")
include("models/scenario.jl")
include("models/jobs.jl")
include("models/events.jl")
include("models/backoff.jl")
include("models/retry.jl")

# Result types are needed by runtime state as well as reporting.
include("reporting/results.jl")

# Runtime storage, event processing and public simulation entry points.
include("simulation/resources.jl")
include("simulation/monitoring.jl")
include("simulation/state.jl")
include("simulation/calendar.jl")
include("simulation/outcomes.jl")
include("simulation/scheduling.jl")
include("simulation/handlers.jl")
include("simulation/engine.jl")

# Single-run statistics, repeated experiments and text rendering.
include("reporting/metrics.jl")
include("reporting/repeated.jl")
include("reporting/display.jl")

end # module QueueLens
