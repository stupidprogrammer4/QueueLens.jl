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

"""
    JobRejection(id, arrival_time, rejection_time, reason)

Record a job refused before entering the worker queue. Rejections are stored
separately from completed `JobResult`s because no service was performed.
The admission bookkeeping helper currently records `:queue_full` as the reason.
"""
struct JobRejection
    id::Int
    arrival_time::Float64
    rejection_time::Float64
    reason::Symbol
end

"""
    ResourceSummary(capacity, mean_queue_length, utilization)

Scalar snapshot of one resource's full-run time-weighted metrics. Queue length
counts waiting jobs; utilization is mean occupied slots divided by capacity.
"""
struct ResourceSummary
    capacity::Int
    mean_queue_length::Float64
    utilization::Float64
end

"""
    MonitoringSummary(duration, worker_capacity, mean_queue_length, worker_utilization, resources)

Time-weighted metrics over [0, duration], including initial idle time and the
final draining interval. Utilization is a fraction, not a percentage; workers
remain occupied during resource waits. Zero-duration runs report zero means
and utilization. `resources` maps names to scalar `ResourceSummary` snapshots,
not live pools or accumulators. Completion-based warm-up does not apply here.
"""
struct MonitoringSummary
    duration::Float64
    worker_capacity::Int
    mean_queue_length::Float64
    worker_utilization::Float64
    resources::Dict{Symbol,ResourceSummary}
end

"""
    SimulationResult(completed, rejected, monitoring)
    SimulationResult(completed, rejected)

Outcomes of one finished simulation. `completed` holds `JobResult`s in
completion order; `rejected` holds `JobRejection`s in rejection order.
Each input job has one outcome. Rejected jobs have no service latency and
must not be included in the completed-job latency statistics.
Simulation entry points always provide `monitoring::MonitoringSummary`.
Manually assembled outcome-only reports may omit it; `nothing` means unavailable,
not zero utilization. Outcomes alone cannot reconstruct resource histories.
"""
struct SimulationResult
    completed::Vector{JobResult}
    rejected::Vector{JobRejection}
    monitoring::Union{Nothing,MonitoringSummary}
end

# Preserve outcome-only construction without inventing missing time histories.
SimulationResult(completed::Vector{JobResult}, rejected::Vector{JobRejection}) =
    SimulationResult(completed, rejected, nothing)

"""
    show(io, ::MIME"text/plain", monitoring::MonitoringSummary)

Display the full observation window and scalar metrics, sorting resource names
so output order does not depend on dictionary insertion order.
"""
function Base.show(io::IO, ::MIME"text/plain", monitoring::MonitoringSummary)
    println(io, "MonitoringSummary (full run, time 0 to ", monitoring.duration, "):")
    println(io, "  worker_capacity: ", monitoring.worker_capacity)
    println(io, "  mean_queue_length: ", monitoring.mean_queue_length)
    println(io, "  worker_utilization: ", monitoring.worker_utilization)
    for name in sort!(collect(keys(monitoring.resources)))
        resource = monitoring.resources[name]
        println(io, "  resource ", name, ": capacity=", resource.capacity,
                ", mean_queue_length=", resource.mean_queue_length,
                ", utilization=", resource.utilization)
    end
end

"""
    show(io, ::MIME"text/plain", result::SimulationResult)

Show outcome counts, the rejected fraction and available time-weighted metrics
without printing every job in a large run.
The full records remain accessible through `completed` and `rejected`.
"""
function Base.show(io::IO, ::MIME"text/plain", result::SimulationResult)
    println(io, "SimulationResult:")
    println(io, "  completed: ", length(result.completed))
    println(io, "  rejected: ", length(result.rejected))
    println(io, "  rejection_rate: ", rejection_rate(result))
    if result.monitoring === nothing
        println(io, "  monitoring: unavailable")
    else
        show(io, MIME"text/plain"(), result.monitoring)
    end
end
