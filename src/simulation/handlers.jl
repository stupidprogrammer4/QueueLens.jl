# Event dispatch and terminal-event filtering.

"""
    handle!(state, event::JobArrival)

A job has arrived. If `can_admit` accepts it, put it at the back of the FIFO
worker queue and try to start one job. Otherwise record a `:queue_full`
rejection without occupying a worker or creating a completion event.

Arrival never starts a job directly: it only makes the queue non-empty and
lets [`start_next_job!`](@ref) decide. That keeps the "may the worker begin?"
rule in exactly one place. Both admission and rejection schedule the next
arrival so a full queue does not stop workload generation.
"""
function handle!(state::SimState, event::JobArrival)
    if can_admit(state, state.queue_capacity)
        state.waiting = push!(state.waiting, event.job_id)
        start_next_job!(state)
    else
        record_rejection!(state, event.job_id)
    end
    schedule_next_arrival!(state)
end

"""
    handle!(state, event::ServiceCompleted)

A worker has finished a job. Record its `JobResult`, release one occupied
slot, then try to start the next waiting job.

The record is deleted once its result is built. A second `ServiceCompleted`
for that job therefore throws `ArgumentError` instead of producing a duplicate
result. Validate attempt identity before changing the live job.
"""
function handle!(state::SimState, event::ServiceCompleted)
    if is_stale_event(state, event)
        return nothing
    end
    if haskey(state.records, event.job_id)
        record = state.records[event.job_id]
        validate_event_attempt(record, event)
        arrival_time = record.arrival_time
        start_time = isnan(record.first_start_time) ? record.start_time : record.first_start_time
        completion_time = state.now
        waiting_time = start_time - arrival_time
        latency = completion_time - arrival_time
        result = JobResult(event.job_id, record.arrival_time, start_time, completion_time, waiting_time, latency)
        push!(state.attempts, AttemptResult(record.id, record.attempt_id, record.start_time,
                                          state.now, length(record.steps), :completed))
        state.terminal_attempts[record.id] = record.attempt_id
        push!(state.results, result)
        delete!(state.records, event.job_id)
        state.in_use -= 1
        start_next_job!(state)
    else
        throw(ArgumentError("ServiceCompleted for unknown job id $(event.job_id)"))
    end
end


"""
    handle!(state, event::StepCompleted)

Finish the current stage after validating the job id and stage index.
Release its resource, if any, and let the first job in that resource's FIFO
queue acquire it before the completing job advances to its next stage.

Stage completion preserves worker occupancy and the original job start time.
If no stages remain, `start_current_step!` schedules whole-job completion.
Unknown jobs, invalid stage indices and unregistered resources throw
`ArgumentError`; releasing an idle pool also throws.
"""
function handle!(state::SimState, event::StepCompleted)
    if is_stale_event(state, event)
        return nothing
    end
    if !haskey(state.records, event.job_id)
        throw(ArgumentError("StepCompleted for unknown job id $(event.job_id)"))
    end
    record = state.records[event.job_id]
    validate_event_attempt(record, event)
    if !(1 <= event.step_index <= length(record.steps))
        throw(ArgumentError("StepCompleted for job id $(event.job_id): expected step index in 1:$(length(record.steps)), got $(event.step_index)"))
    end
    if event.step_index != record.step_index
        throw(ArgumentError("StepCompleted for job id $(event.job_id): expected current step $(record.step_index), got $(event.step_index)"))
    end
    resource = record.steps[event.step_index].resource
    if resource !== nothing
        pool = get(state.resources, resource, nothing)
        if pool === nothing
            throw(ArgumentError("StepCompleted for job id $(event.job_id): resource $(resource) not registered"))
        end
        release_resource!(state, record, resource)
    end
    record.step_active = false
    record.step_index += 1
    start_current_step!(state, event.job_id)
end

"""
    handle!(state, event::JobFailed) -> Nothing

Validate an active fault via record_failure!, then close its attempt, release
its held resource (if any) and worker, and resume waiting work. Resource waiters
must get their FIFO turn before newly admitted worker jobs can take that pool.
Repeat failure events for ids in `state.failed_ids` have no effect.
Retry from step one after backoff if the policy permits; otherwise record a
terminal failure. Invalid faults fail validation before ownership changes.
"""
function handle!(state::SimState, event::JobFailed)
    if is_stale_event(state, event)
        return nothing
    end
    if event.job_id in state.failed_ids
        return nothing
    end
    record = record_failure!(state, event; terminal=false)
    return finish_failed_attempt!(state, record, event.reason)
end

"""
    is_stale_completion(state, event::SimEvent) -> Bool

Identify StepCompleted or ServiceCompleted events belonging
to terminal failed jobs. Other events, including arrivals, are not stale here.
Read state without mutation. Unknown ids are not automatically failed ids.

The shared simulation loop uses this predicate BEFORE advancing the clock; stale
calendar entries must not extend the monitoring window. Completion handlers
also consult it through is_stale_event for direct calls. Terminal job ids are
distinct from attempt identity; this helper retains the terminal-only rule.
"""
function is_stale_completion(state::SimState, event::SimEvent)
    return event isa Union{ServiceCompleted,StepCompleted} && event.job_id in state.failed_ids
end

"""
    is_stale_event(state, event::SimEvent) -> Bool

Extend stale detection to JobTimedOut. A timeout is stale
when its id is absent from state.records, including already completed, failed
or unknown ids. A record waiting for a worker or resource is not absent.
For all other event types, retain is_stale_completion's existing contract:
unknown completions must still reach validation, and arrivals are not stale.
Read only; do not advance time, remove events or modify state.
The loop calls this before advancing the clock, including for timeout tails
in successful runs where failed_ids is empty.

For an AttemptEvent with a live record, an older attempt is stale. Equal and
future attempts are not stale on identity alone; future attempts reach
validation and throw before mutating the live job. Without a live record,
retain the timeout and terminal-completion rules above.
"""
function is_stale_event(state::SimState, event::SimEvent)
    result = false
    has_key = haskey(state.records, event.job_id)
    if event isa AttemptEvent && !has_key &&
       event.attempt_id < get(state.terminal_attempts, event.job_id, 0)
        return true
    end
    if event isa AttemptEvent && has_key
        curr_attempt = state.records[event.job_id].attempt_id
        result = curr_attempt > event.attempt_id
    elseif event isa Union{JobTimedOut,RetryReady}
        result = !has_key
    else
        result = is_stale_completion(state, event)
    end
    return result
end

"""
    handle!(state, event::JobTimedOut) -> Nothing

Ignore stale timeouts; otherwise call record_timeout! before
changing ownership or queues. Validation returns the still-live record.
Remove a resource waiter from its queue without disturbing the remaining FIFO
order or releasing someone else's resource. For an executing job, release
only held_resource (if any) and resume that pool's first waiter. In both cases,
release one worker and start the next worker-queued job, after resource waiters
have had priority. Shared attempt cleanup schedules a retry when budget remains.
Return nothing, including on duplicate or post-completion timeout calls.
"""
function handle!(state::SimState, event::JobTimedOut)
    if is_stale_event(state, event)
        return nothing
    end
    record = record_timeout!(state, event; terminal=false)
    return finish_failed_attempt!(state, record, :timeout)
end

"""Close one attempt, release ownership, then terminate or schedule a worker-free backoff."""
function finish_failed_attempt!(state::SimState, record::JobRecord, reason::Symbol)
    delay = retry_delay(state.retry_policy, record.attempt_id, state.rng)
    ready_at = delay === nothing ? nothing : state.now + delay
    ready_at === nothing || isfinite(ready_at) || throw(ArgumentError("retry timestamp overflow"))
    push!(state.attempts, AttemptResult(record.id, record.attempt_id, record.start_time,
                                      state.now, record.step_index, reason))
    if delay === nothing
        record_terminal_failure!(state, record, reason)
    end
    wanted_res = record.steps[record.step_index].resource
    held_res = record.held_resource
    if held_res !== nothing
        release_resource!(state, record)
    elseif wanted_res !== nothing
        waiting = state.resource_waiting[wanted_res]
        filter!(id -> id != record.id, waiting)
    end
    state.in_use -= 1
    if delay !== nothing
        record.attempt_id += 1
        record.step_index = 1
        record.step_active = false
        record.start_time = NaN
        record.retry_pending = true
        schedule!(state, RetryReady(ready_at, record.id, record.attempt_id))
    end
    start_next_job!(state)
    return nothing
end

"""Readmit a retry through the same bounded FIFO worker queue, without generating arrivals."""
function handle!(state::SimState, event::RetryReady)
    is_stale_event(state, event) && return nothing
    record = state.records[event.job_id]
    validate_event_attempt(record, event)
    record.retry_pending || throw(ArgumentError("job is not waiting for retry"))
    record.retry_pending = false
    if can_admit(state, state.queue_capacity)
        push!(state.waiting, record.id)
        start_next_job!(state)
    else
        record.start_time = record.first_start_time
        record_terminal_failure!(state, record, :retry_queue_full)
    end
    return nothing
end
