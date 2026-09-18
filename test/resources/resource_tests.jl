@testset "resource pool" begin

    @testset "new pools start empty" begin
        pool = QueueLens.ResourcePool(2)
        @test pool.capacity == 2
        @test pool.in_use == 0
    end

    @testset "capacity must be positive" begin
        @test_throws ArgumentError QueueLens.ResourcePool(0)
        @test_throws ArgumentError QueueLens.ResourcePool(-1)
    end

    @testset "acquire fills available slots and can reuse a released slot" begin
        pool = QueueLens.ResourcePool(2)
        acquired = QueueLens.try_acquire!(pool)
        @test acquired === true
        @test pool.in_use == 1
        @test QueueLens.try_acquire!(pool) === true
        @test pool.in_use == 2
        @test QueueLens.try_acquire!(pool) === false
        @test pool.in_use == 2
        QueueLens.release!(pool)
        @test pool.in_use == 1
        @test QueueLens.try_acquire!(pool) === true
        @test pool.in_use == 2
    end

    @testset "release returns nothing and cannot underflow" begin
        pool = QueueLens.ResourcePool(1)
        # Isolate release behavior from the acquisition implementation.
        pool.in_use = 1
        @test QueueLens.release!(pool) === nothing
        @test pool.in_use == 0
        @test_throws ArgumentError QueueLens.release!(pool)
        @test pool.in_use == 0
    end

end

@testset "resource configuration" begin
    scenario = Scenario(Constant(1.0), Constant(1.0), 1, 42)

    @testset "capacities create fresh pools and matching queues" begin
        config = Dict(:db => 2, :http => 3)
        state = QueueLens.SimState(scenario, config, 2)
        other = QueueLens.SimState(scenario, config, 2)
        @test Set(keys(state.resources)) == Set(keys(config))
        @test Set(keys(state.resource_waiting)) == Set(keys(config))
        for (name, capacity) in config
            @test state.resources[name].capacity == capacity
            @test state.resources[name].in_use == 0
            @test isempty(state.resource_waiting[name])
            @test state.resources[name] !== other.resources[name]
            @test state.resource_waiting[name] !== other.resource_waiting[name]
        end
        QueueLens.try_acquire!(state.resources[:db])
        push!(state.resource_waiting[:db], 7)
        @test other.resources[:db].in_use == 0
        @test isempty(other.resource_waiting[:db])
        @test config == Dict(:db => 2, :http => 3)
    end

    @testset "invalid configured capacity ($capacity)" for capacity in (0, -1)
        @test_throws ArgumentError QueueLens.SimState(scenario, Dict(:db => capacity), 2)
    end

    @testset "unused configured pools preserve scenario results" begin
        config = Dict(:db => 2)
        @test simulate(scenario, config, 2).completed == simulate(scenario, Dict{Symbol,Int}(), 2).completed
        @test config == Dict(:db => 2)
    end
end

@testset "resource state" begin
    scenario = Scenario(Constant(1.0), Constant(1.0), 1, 42)
    first_state = QueueLens.SimState(scenario, Dict{Symbol,Int}())
    second_state = QueueLens.SimState(scenario, Dict{Symbol,Int}())

    @test isempty(first_state.resources)
    @test isempty(first_state.resource_waiting)
    @test isempty(second_state.resources)
    @test isempty(second_state.resource_waiting)
    @test first_state.resources !== second_state.resources
    @test first_state.resource_waiting !== second_state.resource_waiting
end

@testset "resource registration" begin
    scenario = Scenario(Constant(1.0), Constant(1.0), 1, 42)

    @testset "named pools and queues are independent" begin
        state = QueueLens.SimState(scenario, Dict{Symbol,Int}())
        @test QueueLens.register_resource!(state, :db, 2) === nothing
        @test state.resources[:db].capacity == 2
        @test state.resources[:db].in_use == 0
        @test isempty(state.resource_waiting[:db])
        @test QueueLens.register_resource!(state, :http, 3) === nothing
        @test state.resources[:http].capacity == 3
        @test state.resources[:db] !== state.resources[:http]
        @test state.resource_waiting[:db] !== state.resource_waiting[:http]

        QueueLens.try_acquire!(state.resources[:db])
        push!(state.resource_waiting[:db], 7)
        @test state.resources[:http].in_use == 0
        @test isempty(state.resource_waiting[:http])
        @test state.in_use == 0
        @test isempty(state.calendar)
    end

    @testset "duplicate registration preserves occupied pool and queue" begin
        state = QueueLens.SimState(scenario, Dict{Symbol,Int}())
        QueueLens.register_resource!(state, :db, 2)
        pool = state.resources[:db]
        queue = state.resource_waiting[:db]
        QueueLens.try_acquire!(pool)
        push!(queue, 7, 9)

        @test_throws ArgumentError QueueLens.register_resource!(state, :db, 5)
        @test state.resources[:db] === pool
        @test state.resource_waiting[:db] === queue
        @test pool.capacity == 2
        @test pool.in_use == 1
        @test queue == [7, 9]
        @test length(state.resources) == length(state.resource_waiting) == 1
    end

    @testset "invalid capacity leaves state unchanged ($capacity)" for capacity in (0, -1)
        state = QueueLens.SimState(scenario, Dict{Symbol,Int}())
        @test_throws ArgumentError QueueLens.register_resource!(state, :db, capacity)
        @test isempty(state.resources)
        @test isempty(state.resource_waiting)

        QueueLens.register_resource!(state, :db, 2)
        pool = state.resources[:db]
        queue = state.resource_waiting[:db]
        @test_throws ArgumentError QueueLens.register_resource!(state, :http, capacity)
        @test !haskey(state.resources, :http)
        @test !haskey(state.resource_waiting, :http)
        @test state.resources[:db] === pool
        @test state.resource_waiting[:db] === queue
    end
end
