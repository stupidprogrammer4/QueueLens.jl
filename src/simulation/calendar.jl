# Calendar operations; CalendarEntry and its ordering are defined with SimState.

"""
    schedule!(state, event)

Put `event` on the calendar, to be handled when virtual time reaches it.

Every entry is stamped with a monotonically increasing `sequence`.
[`isless`](@ref) compares `(time, is_timeout, sequence)`: ordinary events win
over timeouts at equal times; insertion order otherwise remains unchanged.
Two runs with identical inputs therefore always pop events in the same order.

Scheduling an event earlier than `state.now` throws `ArgumentError` to protect
the monotonic virtual clock.

Also rejects an infinite `time`. Some discrete-event simulators use `Inf` as a
"never happens" sentinel; this one does not, so an infinite timestamp can only
mean a computation went wrong upstream, and a run that silently parked an
event at infinity would report results that look complete but are not.
"""
function schedule!(state::SimState, event::SimEvent)
    if event.time < state.now
        throw(ArgumentError("scheduling into the past: now=$(state.now), event.time=$(event.time)"))
    end
    if isinf(event.time)
        throw(ArgumentError("scheduling an event at infinite time is not allowed"))
    end
    entry = CalendarEntry(event, state.next_sequence)
    push!(state.calendar, entry)
    state.next_sequence += 1
    state.max_calendar_size = max(state.max_calendar_size, length(state.calendar))
end

"""
    pop_next!(state) -> SimEvent

Remove and return the earliest event on the calendar, unwrapped from its
`CalendarEntry` — callers deal in events, not in scheduling metadata.

Does NOT advance the clock. Only the main loop in engine.jl does that, so
that there is exactly one place in the codebase where virtual time moves.

Calling this on an empty calendar is a bug in the caller; the main loop is
expected to check first.
"""
function pop_next!(state::SimState)
    entry = pop!(state.calendar)
    return entry.event
end
