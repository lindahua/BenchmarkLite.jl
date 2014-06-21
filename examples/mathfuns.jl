# Example: Compare the performance of some math functions

using BenchmarkLite

## Define VecMath procedures
#
# The configuration is the vector length, represented by an integer
#

type VecMath{Op} <: Proc end

type Sqrt end
calc(::Sqrt, x) = sqrt(x)

type Exp end
calc(::Exp, x) = exp(x)

type Log end
calc(::Log, x) = log(x)

type Sin end
calc(::Sin, x) = sin(x)  

# procedure name
Base.string{Op}(::VecMath{Op}) = string("vec-", lowercase("$Op"))

# pre-allocated arrays for running the procedure
typealias FVecPair (Vector{Float64},Vector{Float64})

# procedure codes
Base.length(p::VecMath, n::Int) = n

Base.isvalid(p::VecMath, n::Int) = (n > 0)

Base.start(p::VecMath, n::Int) = (rand(n), zeros(n))

function Base.run{Op}(p::VecMath{Op}, n::Int, s::FVecPair)
    x, y = s
    op = Op()
    for i = 1:n
        @inbounds y[i] = calc(op, x[i])
    end
end

Base.done(p::VecMath, n, s) = nothing


## perform the benchmark

procs = Proc[ VecMath{Sqrt}(), 
              VecMath{Exp}(), 
              VecMath{Log}(), 
              VecMath{Sin}() ]

cfgs = 2 .^ (4:11)

println("Running log:")
println("--------------------")
rtable = run(procs, cfgs)
@assert isa(rtable, BenchmarkTable)
println()

## show results

show(rtable; unit=:mps, cfghead="len")



