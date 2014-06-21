module BenchmarkLite

import Base: size, length, get, getindex, run, show

export Proc, BenchmarkTable, BenchmarkEntry, cfgname, procname

##### Types

## The abstract type to represent a (typed) procedure
#
# Following methods should be defined on each subtype of Proc
#
# - string(proc):          get a description
# - length(proc, cfg):     the problem size (e.g. the number of elements to process)
# - isvalid(proc, cfg):    test whether a config is valid for the given proc
#
# - s = start(proc, cfg):  set up (not count in the run-time)
# - run(proc, cfg, s):     run the procedure under the given config  
# - done(proc, cfg, s):    tear down (not count in the run-time)
#
abstract Proc


##### Results

type BenchmarkTable
    cfgs::Vector        # length = m
    procs::Vector{Proc} # length = n
    plens::Matrix{Int}      # m-by-n vector, proc lengths
    nruns::Matrix{Int}      # m-by-n matrix, number of repeat times (in measuring stage)
    etime::Matrix{Float64}  # m-by-n matrix, elapsed time (in measuring stage)
end

function BenchmarkTable(cfgs::Vector, procs::Vector{Proc})
    m = length(cfgs)
    n = length(procs)
    plens = zeros(m, n)
    for (i, c) in enumerate(cfgs), (j, p) in enumerate(procs)
        plens[i,j] = length(p, c)
    end
    nruns = zeros(Int, m, n)
    etime = zeros(m, n)
    BenchmarkTable(cfgs, procs, plens, nruns, etime)
end

cfgname(bt::BenchmarkTable, i::Integer) = string(bt.cfgs[i])
procname(bt::BenchmarkTable, i::Integer) = string(bt.procs[i])

immutable BenchmarkEntry
    plen::Int       # proc length
    nruns::Int      # number of repeat times
    etime::Float64  # elapsed time (in seconds)
end

size(bt::BenchmarkTable) = (length(bt.cfgs), length(bt.procs))

size(bt::BenchmarkTable, i::Integer) = i == 1 ? length(bt.cfgs) :
                                       i == 2 ? length(bt.procs) : 1

getindex(bt::BenchmarkTable, i::Integer, j::Integer) = 
    BenchmarkEntry(bt.plens[i,j], bt.nruns[i,j], bt.etime[i,j])


##### Show Results

abstract BenchmarkUnit

type Sec <: BenchmarkUnit end
type Msec <: BenchmarkUnit end
type Usec <: BenchmarkUnit end
type Nsec <: BenchmarkUnit end
type Ups <: BenchmarkUnit end
type Kps <: BenchmarkUnit end
type Mps <: BenchmarkUnit end
type Gps <: BenchmarkUnit end

get(e::BenchmarkEntry, unit::Sec) = e.etime / e.nruns
get(e::BenchmarkEntry, unit::Msec) = e.etime * 1.0e3 / e.nruns
get(e::BenchmarkEntry, unit::Usec) = e.etime * 1.0e6 / e.nruns
get(e::BenchmarkEntry, unit::Nsec) = e.etime * 1.0e9 / e.nruns
get(e::BenchmarkEntry, unit::Ups) = (1.0 * e.plen * e.nruns) / e.etime
get(e::BenchmarkEntry, unit::Kps) = (1.0e-3 * e.plen * e.nruns) / e.etime
get(e::BenchmarkEntry, unit::Mps) = (1.0e-6 * e.plen * e.nruns) / e.etime
get(e::BenchmarkEntry, unit::Gps) = (1.0e-9 * e.plen * e.nruns) / e.etime


function _show_table(bt::BenchmarkTable, unit::BenchmarkUnit, cfghead::String)
    m = length(bt.cfgs)
    n = length(bt.procs)
    S = Array(String, m+1, n+1)
    S[1,1] = cfghead
    for j=1:n; S[1,j+1] = procname(bt,j); end
    for i=1:m; S[i+1,1] = cfgname(bt,i); end

    for j=1:n, i=1:m
        v = get(bt[i,j], unit)::Float64
        S[i+1,j+1] = @sprintf("%.4f", v)
    end
    return S
end

function show(io::IO, bt::BenchmarkTable; unit::Symbol=:sec, cfghead="config")
    # getting all strings first
    u = unit == :sec ? Sec() :
        unit == :msec ? Msec() :
        unit == :usec ? Usec() :
        unit == :nsec ? Nsec() :
        unit == :kps ? Kps() :
        unit == :mps ? Mps() :
        unit == :gps ? Gps() : 
        unit == :ups ? Ups() :
        error("Invalid unit value :$(unit).")
    S = _show_table(bt, u, cfghead)
    nrows, ncols = size(S)

    # calculate the width of each column
    colwids = Array(Int, ncols)
    for j = 1:ncols
        w = 1
        for i = 1:nrows
            wij = length(S[i,j])
            if wij > w; w = wij; end
        end
        colwids[j] = w
    end

    # print the table
    println(io, "$(typeof(bt)) [unit = $unit]")
    for i = 1:nrows
        # first column
        print(io, rpad(S[i,1], colwids[1]))
        print(io, " |  ")
        # remaining columns
        for j = 2:ncols
            print(io, lpad(S[i,j], colwids[j]))
            print(io, "  ")
        end
        println(io)

        if i == 1
            println(io, repeat("-", sum(colwids) + 2 * ncols + 2))
        end
    end
end

show(bt::BenchmarkTable; unit::Symbol=:sec, cfghead="config") = 
    show(STDOUT, bt; unit=unit, cfghead=cfghead)


function Base.writecsv(io::IO, bt::BenchmarkTable)
    println(io, "proc,cfg,length,nruns,elapsed")
    for (j, p) in enumerate(bt.procs)
        pname = string(p)
        for (i, c) in enumerate(bt.cfgs) 
            e = bt[i,j]
            println(io, join({repr(pname), repr(string(c)), e.plen, e.nruns, e.etime}, ","))
        end
    end
end


##### Run Benchmarks

function run{P<:Proc}(p::P, cfg; 
                      nruns::Int = 0, duration::Float64=1.0, allowgc::Bool=true)
    # Run a procedure under a certain config
    #
    # Arguments:
    #
    #   - p:        the procedure to be tested
    #   - cfg:      the configuration to be tested
    #   - nruns:    the number of repeating times (in measuring stage)
    #
    # Keyword arguments:
    #
    #   - duration: the rough duration of the whole multi-run process
    #
    #   When nruns > 0, it runs a fixed number of times in measuring stage,
    #   otherwise, it uses a probing stage to roughly measure the runtime
    #   for each run, and uses it to determine nruns.
    #
    # Returns:  (nruns, etime)
    #
    #   - nruns:    the actual number of running times (in measuring stage)
    #   - etime:    the elapsed seconds (in measuring stage)
    #

    # check validity
    if !isvalid(p, cfg)
        return (0, 0.0)
    end

    # set up
    s = start(p, cfg)

    # warming
    run(p, cfg, s)

    if !allowgc
        gc_disable()
    end

    # probing
    if nruns <= 0
        et = @elapsed run(p, cfg, s)
        # if et is very short, we will perform more accurate probing
        if et < duration / 500
            nr = max(iceil(duration / 500), 2)
            et2 = @elapsed for i=1:nr 
                run(p, cfg, s)
            end
            et = et2 / nr
        end
        nruns = iceil(duration / et)
    end

    # measuring
    etime = @elapsed for i = 1:nruns
        run(p, cfg, s)
    end

    # tear down
    done(p, cfg, s)

    if !allowgc
        gc_enable()
    end

    return (nruns, etime)
end


function run(procs::Vector{Proc}, cfgs::Vector; 
             duration::Float64=1.0, verbose::Int=2, logger::IO=STDOUT)
    # Run a list of procedures against a list of configurations
    #
    # Arguments:
    #
    #   - procs:    the list of procedures to run
    #   - cfgs:     the list of configurations to run
    #   
    # Keyword arguments:
    #
    #   - duration: the duration for each procedure on each config
    #   - verbose:  0 - prints nothing 
    #               1 - prints one line for each procedure 
    #               2 - prints one line for each procedure on each config
    #   - logger:   the IO to which the information is sent
    #   
    # Returns: a BenchmarkTable instance capturing all results
    #

    bt = BenchmarkTable(cfgs, procs)
    m = length(cfgs)
    n = length(procs)
    for (j, p) in enumerate(procs)
        procname = string(p)
        verbose >= 1 && println(logger, "Benchmarking $procname ...")

        for (i, cfg) in enumerate(cfgs)
            cfgname = string(cfg)
            (nr, et) = run(p, cfg; duration=duration)

            bt.nruns[i, j] = nr
            bt.etime[i, j] = et

            verbose >= 2 && 
                println(logger, "  $procname with cfg = $cfgname: nruns = $nr, elapsed = $et secs")
        end
    end
    return bt
end


end # module
