# Input jobs and their sequential service steps.

"""
    ServiceStep(resource::Union{Nothing,Symbol}, duration::Float64)

Describe one sequential stage of a job. `resource` names a shared pool, or is
`nothing` when the stage needs only a worker. Pool existence is checked when
the step is connected to a simulation, not by this constructor.

`duration` is service time in seconds after acquiring any required resource;
it excludes resource waiting. Zero is allowed. Negative or non-finite values
throw `ArgumentError`.
"""
struct ServiceStep
    resource::Union{Nothing,Symbol}
    duration::Float64
    failure_probability::Float64

    # Reject invalid durations here so all steps are safe to schedule.
    function ServiceStep(resource::Union{Nothing,Symbol}, duration::Float64;
                         failure_probability::Real=0.0)
        if duration < 0 || !isfinite(duration)
            throw(ArgumentError("service step duration must be nonnegative"))
        end
        probability = Float64(failure_probability)
        isfinite(probability) && 0 <= probability <= 1 ||
            throw(ArgumentError("failure_probability must be in [0, 1]"))
        new(resource, float(duration), probability)
    end
end

"""
    Job(id, arrival_time, service_time; timeout = nothing)
    Job(id, arrival_time, steps::Vector{ServiceStep}; timeout = nothing)
    Job(id, arrival_time; timeout = nothing)

A unit of work entering the system with an ordered list of service steps.
The scalar-duration constructor creates one step with no shared resource.
Omitting steps or supplying an empty vector gives zero total service time.

`arrival_time` must be finite and nonnegative. `service_time` is the finite
sum of step durations computed at construction. The engine executes each
step separately; this cached total excludes all waiting time.

`timeout` is a positive finite duration from worker start, including resource
waits but excluding the initial worker queue. `nothing` disables the deadline.
It applies to the whole job, not each stage. Completion at the deadline wins.

The supplied step vector is stored by reference. Treat it as read-only after
construction so the cached total stays consistent with the steps.
"""
struct Job
    id::Int
    arrival_time::Float64
    service_time::Float64
    steps::Vector{ServiceStep}
    timeout::Union{Nothing,Float64}

    # Validate arrival and the cached total, including overflow when summing steps.
    function Job(id::Int, arrival_time::Float64, steps::Vector{ServiceStep}=Vector{ServiceStep}();
                 timeout::Union{Nothing,Real} = nothing)
        if arrival_time < 0 || !isfinite(arrival_time)
            throw(ArgumentError("job arrival time must be nonnegative"))
        end
        service_time = sum((step.duration for step in steps); init=0.0)
        if service_time < 0 || !isfinite(service_time)
            throw(ArgumentError("job service time must be nonnegative"))
        end
        limit = timeout === nothing ? nothing : Float64(timeout)
        if limit !== nothing && (!isfinite(limit) || limit <= 0.0)
            throw(ArgumentError("job timeout must be finite and positive, or nothing"))
        end
        new(id, float(arrival_time), float(service_time), steps, limit)
    end
end

"""
    Job(id::Int, arrival_time::Float64, service_time::Float64; timeout = nothing)

Represent scalar service time as one resource-free stage. Delegate duration
validation to `ServiceStep` and arrival validation to the step-based constructor.
"""
function Job(id::Int, arrival_time::Float64, service_time::Float64;
             timeout::Union{Nothing,Real} = nothing)
    steps = [ServiceStep(nothing, service_time)]
    return Job(id, arrival_time, steps; timeout)
end
