# Job entities: the input, the in-flight bookkeeping, and the output.

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

    # Reject invalid durations here so all steps are safe to schedule.
    function ServiceStep(resource::Union{Nothing,Symbol}, duration::Float64)
        if duration < 0 || !isfinite(duration)
            throw(ArgumentError("service step duration must be nonnegative"))
        end
        new(resource, float(duration))
    end
end

"""
    Job(id, arrival_time, service_time)
    Job(id, arrival_time, steps::Vector{ServiceStep})
    Job(id, arrival_time)

A unit of work entering the system with an ordered list of service steps.
The scalar-duration constructor creates one step with no shared resource.
Omitting steps or supplying an empty vector gives zero total service time.

`arrival_time` must be finite and nonnegative. `service_time` is the finite
sum of step durations computed at construction. The engine executes each
step separately; this cached total excludes all waiting time.

The supplied step vector is stored by reference. Treat it as read-only after
construction so the cached total stays consistent with the steps.
"""
struct Job
    id::Int
    arrival_time::Float64
    service_time::Float64
    steps::Vector{ServiceStep}

    # Validate arrival and the cached total, including overflow when summing steps.
    function Job(id::Int, arrival_time::Float64, steps::Vector{ServiceStep}=Vector{ServiceStep}())
        if arrival_time < 0 || !isfinite(arrival_time)
            throw(ArgumentError("job arrival time must be nonnegative"))
        end
        service_time = sum((step.duration for step in steps); init=0.0)
        if service_time < 0 || !isfinite(service_time)
            throw(ArgumentError("job service time must be nonnegative"))
        end
        new(id, float(arrival_time), float(service_time), steps)
    end
end

"""
    Job(id::Int, arrival_time::Float64, service_time::Float64)

Represent scalar service time as one resource-free stage. Delegate duration
validation to `ServiceStep` and arrival validation to the step-based constructor.
"""
function Job(id::Int, arrival_time::Float64, service_time::Float64)
    steps = [ServiceStep(nothing, service_time)]
    return Job(id, arrival_time, steps)
end

"""
    JobRecord(job)

Mutable bookkeeping for a job that is currently inside the system.

The engine retains job timing and steps here while events progress through
the calendar. `arrival_time` and `start_time` determine waiting time when the
final `JobResult` is built.

`start_time` is `NaN` until the job actually enters service. Milestone 4 will
add `attempt` and timeout bookkeeping here.

`steps` retains the job's read-only stage descriptions. `step_index` starts at
1 and identifies the next unfinished stage. An index beyond `length(steps)`
means none remain, including for a job with no steps. The `StepCompleted`
handler advances this index without releasing the job's worker slot.
"""
mutable struct JobRecord
    id::Int
    arrival_time::Float64
    service_time::Float64
    start_time::Float64
    steps::Vector{ServiceStep}
    step_index::Int
end

# Share the read-only steps; each record starts with its own unset start time and index.
JobRecord(job::Job) = JobRecord(job.id, job.arrival_time, job.service_time, NaN, job.steps, 1)

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
