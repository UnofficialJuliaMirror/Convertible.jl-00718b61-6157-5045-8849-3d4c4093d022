module Convertible

import Base: convert
import Iterators: product
import DataStructures: PriorityQueue, enqueue!, unshift!, dequeue!

export @convertible, @convert, isconvertible

const nodes = Set{DataType}()

"""
    @convertible

`@convertible <type-def>` adds the `isconvertible` trait to the (struct) type defined in `<type-def>`.
"""
macro convertible(ex)
    wrongex = false
    if typeof(ex) == Expr && typeof(ex) != Symbol
        if ex.head == :type
            typ = ex.args[2]
            if typeof(typ) == Expr
                error("@convertible cannot be used on parametric types. Use it on an alias instead without free parameters instead.")
            end
        elseif ex.head == :const
            typ = ex.args[1].args[1]
        else
            wrongex = true
        end
    else
        wrongex = true
    end
    wrongex && error("@convertible must be used on a type definition.")

    return quote
        $(esc(ex))
        Convertible.isconvertible(::Type{$(esc(typ))}) = true
        push!(Convertible.nodes, $(esc(typ)))
        nothing
    end
end

macro convert(ex)
    if typeof(ex) != Expr && ex.head != :block
        error("@convert must be used on a code block, e.g. `@convert begin ... end`.")
    end
    for (i, e) in enumerate(ex.args)
        if typeof(e) == Expr && e.head in (:function, :(=))
            if e.args[1].args[1] == :convert
                ex.args[i].args[1].args[1] = :(Convertible._convert)
            end
        end
    end
    return quote
        $(esc(ex))
    end
end

isconvertible{T}(::Type{T}) = false

_convert{T,S}(::Type{T}, obj::S) = _convert(T, obj, Val{isconvertible(T)}, Val{isconvertible(S)})
_convert{T}(::Type{T}, obj, ::Type{Val{true}}, ::Type{Val{true}}) = __convert(T, obj)
_convert{T}(::Type{T}, obj, ::Type{Val{false}}, ::Type{Val{false}}) = convert(T, obj)

function graph()
    g = Dict{DataType,Set{DataType}}(t => Set{DataType}() for t in nodes)
    for (ti, tj) in product(nodes, nodes)
        ti == tj && continue

        m = methods(_convert, (Type{tj}, ti))
        # Dirty hack to determine if the method isn't the generic fallback
        if !isempty(m) && m.ms[1].module != Convertible
            push!(g[ti], tj)
        end
    end
    return g
end

function haspath(graph, origin, target)
    haspath = false
    queue = [origin]
    links = Dict{DataType, DataType}()
    while !isempty(queue)
        node = shift!(queue)
        if node == target
            break
        end
        for n in graph[node]
            if !haskey(links, n)
                push!(queue, n)
                merge!(links, Dict{DataType, DataType}(n=>node))
            end
        end
    end
    if haskey(links, target)
        haspath = true
    end
    return haspath
end

function findpath(origin, target)
    g = graph()
    if isempty(g[origin])
        error("There are no convert methods with source type '$origin' defined.")
    end
    if !haspath(g, origin, target)
        error("No conversion path '$origin' -> '$target' found.")
    end
    queue = PriorityQueue(DataType, Int)
    prev = Dict{DataType,Nullable{DataType}}()
    distance = Dict{DataType, Int}()
    for node in keys(g)
        merge!(prev, Dict(node=>Nullable{DataType}()))
        merge!(distance, Dict(node=>typemax(Int)))
        enqueue!(queue, node, distance[node])
    end
    distance[origin] = 0
    queue[origin] = 0
    while !isempty(queue)
        node = dequeue!(queue)
        node == target && break
        for neighbor in g[node]
            alt = distance[node] + 1
            if alt < distance[neighbor]
                distance[neighbor] = alt
                prev[neighbor] = Nullable(node)
                queue[neighbor] = alt
            end
        end
    end
    path = DataType[]
    n = target
    while !isnull(prev[n])
        unshift!(path, n)
        n = get(prev[n])
    end
    return path
end

function gen_convert(T, S, obj)
    ex = :(obj)
    path = findpath(S, T)
    for t in path
        ex = :(Convertible._convert($t, $ex))
    end
    return :($ex)
end

@generated function __convert{T,S}(::Type{T}, obj::S)
    gen_convert(T, S, obj)
end

end # module
