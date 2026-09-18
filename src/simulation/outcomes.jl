# Validated terminal-outcome bookkeeping; slot ownership stays with handlers.

"""
    validate_event_attempt(record, event::AttemptEvent) -> Nothing

Require an event to target the live attempt before changing ownership or outcomes.
Stale events must be filtered by the caller first. A mismatch reaching this
guard throws without mutation; future attempts are invalid, not stale.
"""
function validate_event_attempt(record::JobRecord, event::AttemptEvent)
    if event.attempt_id != record.attempt_id
        throw(ArgumentError("$(nameof(typeof(event))) for job id $(event.job_id): expected attempt $(record.attempt_id), got $(event.attempt_id)"))
    end
    return nothing
end

"""
    record_rejection!(state, job_id) -> Nothing

Record a `:queue_full` rejection at `state.now` and remove the job's active
record. The caller decides admission before enqueueing or starting the job.
Unknown, already queued, started, or not-yet-arrived jobs throw `ArgumentError`
without changing state. Repeating a rejection fails because its record is gone.

This bookkeeping helper does not release workers, modify queues, or schedule
events. The arrival handler must still schedule the next arrival.
"""
function record_rejection!(state::SimState, job_id::Int)
    if !haskey(state.records, job_id)
        throw(ArgumentError("cannot reject unknown job id $job_id"))
    end
    record = state.records[job_id]
    if !isnan(record.start_time) || job_id in state.waiting
        throw(ArgumentError("cannot reject already admitted job id $job_id"))
    end
    if state.now < record.arrival_time
        throw(ArgumentError("cannot reject job id $job_id before its arrival"))
    end
    push!(state.rejected, JobRejection(job_id, record.arrival_time, state.now, :queue_full))
    delete!(state.records, job_id)
    return nothing
end

"""
    record_failure!(state, event::JobFailed) -> JobRecord

Validate an active-stage failure, append its terminal outcome, remember its id
and remove its in-flight record. Return that record so the handler can inspect
the resource it held. Does NOT free workers or resources, wake queues, cancel
events or update monitoring: those belong to event dispatch.

With terminal=false, perform the same validation and return the live record
without recording a terminal outcome. Retry-aware handlers use this mode.

Call before changing the active-step metadata. Unknown or previously terminal
jobs, wrong stages, waiting jobs, inconsistent ownership and mismatched event
times throw `ArgumentError` before any mutation. Repeat failures are handled
by the caller using `failed_ids`; this bookkeeping helper rejects duplicates.
"""
function record_failure!(state::SimState, event::JobFailed; terminal::Bool=true)
    if event.time != state.now
        throw(ArgumentError("failure time must match the simulation clock"))
    end
    if event.job_id in state.failed_ids || !haskey(state.records, event.job_id)
        throw(ArgumentError("cannot record failure for unknown or terminal job id $(event.job_id)"))
    end
    record = state.records[event.job_id]
    validate_event_attempt(record, event)
    if !record.step_active || !isfinite(record.start_time) ||
       !(record.arrival_time <= record.start_time <= state.now) ||
       event.step_index != record.step_index ||
       !(1 <= record.step_index <= length(record.steps))
        throw(ArgumentError("failure must target the job's currently executing stage"))
    end
    if state.in_use <= 0 || event.job_id in state.waiting ||
       any(queue -> event.job_id in queue, values(state.resource_waiting))
        throw(ArgumentError("failed job must hold a worker and must not be queued"))
    end
    resource = record.held_resource
    if resource !== record.steps[record.step_index].resource
        throw(ArgumentError("held resource must match the executing stage"))
    end
    if resource !== nothing &&
       (!haskey(state.resources, resource) || state.resources[resource].in_use <= 0)
        throw(ArgumentError("failed job's resource must have an occupied slot"))
    end
    return terminal ? record_terminal_failure!(state, record, event.reason) : record
end

"""
    record_timeout!(state, event::JobTimedOut) -> JobRecord

Validate a live job at its configured deadline, append a JobFailure with reason
:timeout, remember its failed id and remove its record. Return the removed
record with ownership and stage metadata intact. Accept an executing stage or
a resource waiter that still holds a worker, but never a worker-queued job.

All validation precedes mutation. This helper does not remove resource queue
entries, release slots, wake jobs, cancel events or update monitoring. Those
actions belong to the timeout handler. Unknown/terminal ids are
rejected here; the handler must ignore stale timeout events before calling it.
With terminal=false, validation returns the still-live record without mutation.
"""
function record_timeout!(state::SimState, event::JobTimedOut; terminal::Bool=true)
    if event.time != state.now
        throw(ArgumentError("timeout time must match the simulation clock"))
    end
    if event.job_id in state.failed_ids || !haskey(state.records, event.job_id)
        throw(ArgumentError("cannot record timeout for unknown or terminal job id $(event.job_id)"))
    end
    record = state.records[event.job_id]
    validate_event_attempt(record, event)
    if record.timeout === nothing || !isfinite(record.start_time) ||
       !(record.arrival_time <= record.start_time < state.now) ||
       record.start_time + record.timeout != state.now
        throw(ArgumentError("timeout must occur at the started job's configured deadline"))
    end
    if state.in_use <= 0 || event.job_id in state.waiting ||
       !(1 <= record.step_index <= length(record.steps))
        throw(ArgumentError("timed-out job must hold a worker and have an unfinished stage"))
    end
    resource = record.steps[record.step_index].resource
    queued_count = sum((count(==(event.job_id), queue)
                        for queue in values(state.resource_waiting)); init=0)
    if record.step_active
        if queued_count != 0 || record.held_resource !== resource
            throw(ArgumentError("executing job must not be queued and must hold its stage's resource"))
        end
        if resource !== nothing &&
           (!haskey(state.resources, resource) || state.resources[resource].in_use <= 0)
            throw(ArgumentError("timed-out job's held resource must have an occupied slot"))
        end
    else
        if record.held_resource !== nothing || resource === nothing ||
           !haskey(state.resources, resource) || !haskey(state.resource_waiting, resource) ||
           queued_count != 1 || !(event.job_id in state.resource_waiting[resource])
            throw(ArgumentError("inactive started job must wait exactly once for its stage's resource"))
        end
    end
    return terminal ? record_terminal_failure!(state, record, :timeout) : record
end

"""
    record_terminal_failure!(state, record, reason) -> JobRecord

Store a failure and remove its live record after event-specific validation.
Internal bookkeeping shared by record_failure! and record_timeout!: callers
must validate before invoking this mutation-only helper. Return the removed
record unchanged so the handler can release its worker and resource ownership.
"""
function record_terminal_failure!(state::SimState, record::JobRecord, reason::Symbol)
    push!(state.failed, JobFailure(record.id, record.arrival_time, record.start_time,
                                  state.now, record.step_index, reason))
    push!(state.failed_ids, record.id)
    state.terminal_attempts[record.id] = record.attempt_id
    delete!(state.records, record.id)
    return record
end
