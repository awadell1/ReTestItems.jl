###
### testsetup
###
"""
    TestSetup(name, code)

A module that a `TestItem` can require to be evaluated before that `TestItem` is run.
Used for declaring code that multiple `TestItem`s rely on.
Should only be created via the `@testsetup` macro.
"""
struct TestSetup
    name::Symbol
    code::Any
    file::String
end

"""
    @testsetup module MyTestSetup
        # code that can be shared between @testitems
    end
"""
macro testsetup(mod)
    mod.head == :module || error("`@testsetup` expects a `module ... end` argument")
    _, name, code = mod.args
    name isa Symbol || error("`@testsetup module` expects a valid module name")
    nm = QuoteNode(name)
    q = QuoteNode(code)
    esc(quote
        $store_testsetup($TestSetup($nm, $q, $(String(__source__.file))))
    end)
end

function store_testsetup(ts::TestSetup)
    @debugv 2 "expanding test setup $(ts.name)"
    tls = task_local_storage()
    setups = get(tls, :TestSetup, nothing)
    if setups === nothing
        # we're not in a runtests context, so just use ReTestItems global TestContext
        GLOBAL_TEST_CONTEXT_FOR_TESTING.setups_quoted[String(ts.name)] = ts
    else
        put!(setups, ts)
    end
    return nothing
end

# retrieve a test setup by name; ONLY FOR TESTING
function get_test_setup(name)
    tls = task_local_storage()
    setups = get(tls, :TestSetup, nothing)
    if setups === nothing
        # we're not in a runtests context, so just use ReTestItems global TestContext
        return GLOBAL_TEST_CONTEXT_FOR_TESTING.setups_quoted[String(name)]
    else
        throw(ArgumentError("test setup $name not found"))
    end
end

###
### testitem
###
# NOTE: TestItems are serialized across processes for
# distributed testing, so care needs to be taken that
# fields are serialization-appropriate and process-local
# state is managed externally like TestContext in runtests
"""
    TestItem

A single, independently runnable group of tests.
Used to wrap tests that must be run together, similar to a `@testset`, but encapsulating
those test in their own module.
Should only be created via the `@testitem` macro.
"""
struct TestItem
    name::String
    tags::Vector{Symbol}
    default_imports::Bool
    setup::Vector{Symbol}
    file::String
    code::Any
end

"""
    @testitem "name" [tags=[] setup=[] default_imports=true] begin
        # code that will be run as tests
    end

A single, independently runnable group of tests.

A test item is a standalone block of tests, and cannot access names from the surrounding scope. Multiple test items may run in parallel, executing on distributed processes.

A `@testitem` can contain a single test:

    @tesitem "Arithmetic" begin
        @test 1 + 1 == 2
    end

Or it can contain many tests, which can be arranged in `@testsets`:

    @testitem "Arithmetic" begin
        @testset "addition" begin
            @test 1 + 2 == 3
            @test 1 + 0 == 1
        end
        @testset "multiplication" begin
            @test 1 * 2 == 2
            @test 1 * 0 == 0
        end
        @test 1 + 2 * 2 == 5
    end

A `@testitem` is wrapped into a module when run, so must import any additional packages:

    @testitem "Arithmetic" begin
        using LinearAlgebra
        @testset "multiplication" begin
            @test dot(1, 2) == 2
        end
    end

The test item's code is evaluated as top-level code in a new module, so it can include imports, define new structs or helper functions, and declare tests and testsets.

    @testitem "DoCoolStuff" begin
        function do_really_cool_stuff()
            # ...
        end
        @testset "cool stuff doing" begin
            @test do_really_cool_stuff()
        end
    end

By default, `Test` and the package being tested will be loaded into the `@testitem`.
This can be disabled by passing `default_imports=false`.

A `@testitem` can use test-specific setup code declared with `@testsetup`, by passing the
name of the test setup module with the `setup` keyword:

    @testsetup module TestIrrationals
        const PI = 3.14159
        const INV_PI = 0.31831
        area(radius) = PI * radius^2
        export PI, INV_PI, area
    end
    @testitem "Arithmetic" setup=[TestIrrationals] begin
        @test 1 / PI ≈ INV_PI atol=1e-6
    end
    @testitem "Geometry" setup=[TestIrrationals] begin
        @test area(1) ≈ PI
    end
"""
macro testitem(nm, exs...)
    default_imports = true
    tags = Symbol[]
    setup = Any[]
    if length(exs) > 1
        for ex in exs[1:end-1]
            ex.head == :(=) || error("`@testitem` options must be passed as keyword arguments")
            if ex.args[1] == :tags
                tags = ex.args[2]
                @assert tags isa Expr "`tags` keyword must be passed a collection of `Symbol`s"
            elseif ex.args[1] == :default_imports
                default_imports = ex.args[2]
                @assert default_imports isa Bool "`default_imports` keyword must be passed a `Bool`"
            elseif ex.args[1] == :setup
                setup = ex.args[2]
                @assert setup isa Expr "`setup` keyword must be passed a collection of `@testsetup` names"
                setup = map(Symbol, setup.args)
            else
                error("unknown `@testitem` keyword arg `$(ex.args[1])`")
            end
        end
    end
    if isempty(exs) || !(exs[end] isa Expr && exs[end].head == :block)
        error("expected `@testitem` to have a body")
    end
    q = QuoteNode(exs[end])
    ti = gensym()
    esc(quote
        $ti = $TestItem($nm, $tags, $default_imports, $setup, $(String(__source__.file)), $q)
        $store_test_item($ti)
        $ti
    end)
end

function store_test_item(ti::TestItem)
    @debugv 2 "expanding test item $(ti.name)"
    tls = task_local_storage()
    if haskey(tls, :__RE_TEST_CHANNEL__)
        put!(tls[:__RE_TEST_CHANNEL__], ti)
    end
    return nothing
end