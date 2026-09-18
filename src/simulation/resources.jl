"""
    ResourcePool(capacity::Int)

Create a pool with positive capacity and zero occupied slots.
Non-positive capacity throws `ArgumentError`.

The pool counts occupied slots; job ownership and FIFO waiting are managed
separately by simulation state and event handlers.
"""
mutable struct ResourcePool
    capacity::Int
    in_use::Int
end

"""
    ResourcePool(capacity::Int)

Validate positive capacity and create a pool with no occupied slots.
Waiting queues are registered separately by `register_resource!`.
"""
function ResourcePool(capacity::Int)
    if capacity <= 0
        throw(ArgumentError("capacity must be positive"))
    end
    return ResourcePool(capacity, 0,)
end

"""
    try_acquire!(pool::ResourcePool) -> Bool

Occupy one available slot and return `true`. If the pool is full, return
`false` without changing it. This operation does not enqueue a waiting job.
"""
function try_acquire!(pool::ResourcePool)
    result::Bool = false
    if pool.in_use < pool.capacity
        pool.in_use += 1
        result = true
    end
    return result
end

"""
    release!(pool::ResourcePool) -> Nothing

Release one occupied slot and return `nothing`. Throw `ArgumentError` if
no slots are occupied. Waking a waiting job is the caller's responsibility.
"""
function release!(pool::ResourcePool)
    if pool.in_use > 0
        pool.in_use -= 1
    else
        throw(ArgumentError("release! called on empty ResourcePool"))
    end
    return nothing
end
