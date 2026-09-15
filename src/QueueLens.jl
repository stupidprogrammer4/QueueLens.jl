module QueueLens

# Public API
export Job, JobResult
export Summary, summarize
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
include("state.jl")
include("metrics.jl")
include("engine.jl")

end # module QueueLens
