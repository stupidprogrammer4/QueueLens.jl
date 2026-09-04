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

The worker finishes serving `job_id` at `time`, and becomes free.
"""
struct ServiceCompleted <: SimEvent
    time::Float64
    job_id::Int
end
