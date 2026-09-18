# The event hierarchy.
#
# Events are immutable: an event is a scheduled fact about the future, and
# nothing should be able to rewrite it once it is on the calendar.
#
# Every concrete event MUST have a `time::Float64` field. The calendar in
# state.jl orders events by time, then defers timeouts behind ordinary events
# at the same instant, with insertion order within each group.

"""
    SimEvent

Abstract supertype for everything that can happen at a point in virtual time.

Adding a new kind of event means adding a subtype here and one `handle!`
method in engine.jl. The main loop never changes.
"""
abstract type SimEvent end

"""
    JobArrival(time, job_id)

A job enters the system at `time`.
"""
struct JobArrival <: SimEvent
    time::Float64
    job_id::Int
end

"""
    JobTimedOut(time, job_id)

The whole-job deadline measured from worker start has been reached. The job
may be executing a stage or waiting for a resource while holding its worker.
Completion at this exact time wins: the calendar processes ordinary events
before timeouts. A timeout for a job already removed from records is stale.
Time must be finite and nonnegative. Runtime deadline validation is separate.
"""
struct JobTimedOut <: SimEvent
    time::Float64
    job_id::Int

    # Reject malformed timestamps before they can enter the calendar.
    function JobTimedOut(time::Float64, job_id::Int)
        if !isfinite(time) || time < 0.0
            throw(ArgumentError("timeout time must be finite and nonnegative"))
        end
        new(time, job_id)
    end
end

"""
    ServiceCompleted(time, job_id)

A worker finishes serving `job_id` at `time`, releasing one service slot.
"""
struct ServiceCompleted <: SimEvent
    time::Float64
    job_id::Int
end

"""
    StepCompleted(time, job_id, step_index)

The indexed stage of `job_id` finishes at `time`. Completing a stage does not
by itself mean the job is finished or its worker slot can be released.

The event carries the stage index so its handler can compare it with the
job record's current stage. Its handler releases the stage's resource, wakes
the first waiting job for that pool, and advances the completing job.
"""
struct StepCompleted <: SimEvent
    time::Float64
    job_id::Int
    step_index::Int
end

"""
    JobFailed(time, job_id, step_index, reason = :injected)

Deterministic failure of an actively executing stage. This exercise has no
retries: the failure ends the logical job. The stage index prevents a fault
intended for one stage from being applied to another. Time must be finite and
nonnegative, and the stage index positive. Runtime state is validated separately.
Faults targeting waiting jobs or stages that have already ended are invalid.
Equal-time events retain the calendar's insertion order.
"""
struct JobFailed <: SimEvent
    time::Float64
    job_id::Int
    step_index::Int
    reason::Symbol

    # Validate the event's shape without assuming a particular simulation state.
    function JobFailed(time::Float64, job_id::Int, step_index::Int, reason::Symbol = :injected)
        if !isfinite(time) || time < 0.0
            throw(ArgumentError("failure time must be finite and nonnegative"))
        end
        if step_index <= 0
            throw(ArgumentError("failure step index must be positive"))
        end
        new(time, job_id, step_index, reason)
    end
end
