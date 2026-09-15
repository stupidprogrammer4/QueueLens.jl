# Simulation state and the event calendar.

using DataStructures: BinaryMinHeap

"""
    CalendarEntry(event, sequence)

An event together with the scheduling metadata the calendar needs to order it.

The wrapper exists so that events stay purely about the domain: `JobArrival`
says a job arrived and knows nothing about how ties happen to be broken.
Adding `RetryReady` in milestone 4 therefore needs no scheduling fields of
its own — the calendar wraps it automatically.
"""
struct CalendarEntry
    time::Float64
    sequence::Int
    event::SimEvent
end

CalendarEntry(event::SimEvent, sequence::Int) = CalendarEntry(event.time, sequence, event)


"""
    isless(a::CalendarEntry, b::CalendarEntry)

Total order on calendar entries: earlier `time` first, and among equal times,
smaller `sequence` first.

This is what makes runs reproducible. A binary heap is not a stable sort, so
without the `sequence` tiebreaker two events sharing a timestamp could come
out in either order depending on the heap's internal layout, and two runs of
the same scenario could diverge.
"""
function Base.isless(a::CalendarEntry, b::CalendarEntry)
    return a.time < b.time || (a.time == b.time && a.sequence < b.sequence)
end

"""
    SimState(scenario, capacity = 1, rng = Xoshiro(scenario.seed))

Everything that changes as the simulation runs. Mutable by definition.

`capacity` must be positive. All slots start idle (`in_use == 0`).

Parameterised on the RNG type so that `rng` has a concrete type in the hot
loop. An abstract RNG field would hide the concrete type from inference;
the type parameter lets methods specialise on the RNG used by the run.

Fields:

  - `rng`            — the run's source of randomness for workload sampling.
  - `scenario`       — the run's description, so handlers can draw the next
                       arrival without threading it through every signature.
  - `now`            — the virtual clock. Only the main loop writes it.
  - `calendar`       — pending events as a min-heap. See [`schedule!`](@ref).
  - `next_sequence`  — stamp for the next entry, giving equal timestamps a
                       deterministic order. Only [`schedule!`](@ref) advances it.
  - `waiting`        — ids of jobs queued for worker slots, in FIFO order.
  - `capacity`       — the maximum number of jobs that can be served simultaneously.
  - `in_use`         — the number of jobs currently being served.
  - `records`        — in-flight bookkeeping, keyed by job id.
  - `results`        — completed jobs, in completion order.
  - `clock_log`      — clock values appended by the monotonicity test's loop.
                       Production simulation loops do not populate it.
  - `jobs_generated` — how many arrivals have been created so far. Generation
                       stops once this reaches `scenario.num_jobs`, which is
                       also how `simulate(::Vector{Job})` disables lazy
                       generation: it starts the counter already at the limit.
  - `max_calendar_size` — high-water mark of the calendar, maintained by
                       [`schedule!`](@ref). Instrumentation only: it is what
                       proves lazy arrival generation actually keeps the
                       calendar small.
"""
mutable struct SimState{R<:AbstractRNG}
    rng::R
    scenario::Scenario
    now::Float64
    calendar::BinaryMinHeap{CalendarEntry}
    next_sequence::Int
    waiting::Vector{Int}
    capacity::Int
    in_use::Int
    records::Dict{Int,JobRecord}
    results::Vector{JobResult}
    clock_log::Vector{Float64}
    jobs_generated::Int
    max_calendar_size::Int
end

function SimState(scenario::Scenario, capacity::Int = 1, rng::R = Xoshiro(scenario.seed)) where {R<:AbstractRNG}
    if capacity <= 0
        throw(ArgumentError("capacity must be positive"))
    end
    return SimState{R}(rng, scenario, 0.0, BinaryMinHeap{CalendarEntry}(), 0,
                       Int[], capacity, 0, Dict{Int,JobRecord}(), JobResult[], Float64[], 0, 0)
end

"""
    schedule!(state, event)

Put `event` on the calendar, to be handled when virtual time reaches it.

Ties are broken by insertion order: every entry is stamped with a
monotonically increasing `sequence`, and [`isless`](@ref) compares
`(time, sequence)`. Two runs with identical inputs therefore always pop
events in the same order.

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
