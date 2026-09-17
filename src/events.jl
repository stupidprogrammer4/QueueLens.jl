# The event hierarchy.
#
# Events are immutable: an event is a scheduled fact about the future, and
# nothing should be able to rewrite it once it is on the calendar.
#
# Every concrete event MUST have a `time::Float64` field. The calendar in
# state.jl orders events by that field and does not know anything else
# about them.

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
