module QueueLens

# ---------- Public API ----------
export Job, JobResult
export Scenario
export Distribution, Constant, Exponential, LogNormal, sample
export simulate

# ---------- Implementation ----------
# Order matters: types must be defined before they are named in another
# type's fields or in a method signature.
include("distributions.jl")  # Distribution, Constant, Exponential, LogNormal, sample
include("scenario.jl")     # Scenario
include("jobs.jl")      # Job, JobRecord, JobResult
include("events.jl")    # SimEvent and its subtypes
include("state.jl")     # SimState, schedule!, pop_next!
include("engine.jl")    # handle!, start_next_job!, simulate

end # module QueueLens
