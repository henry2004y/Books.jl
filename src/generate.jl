"""
    UserExpr(expr::String, indentation::Int)

Struct containing the user provided `expr::String` and it's `indentation::Int` in number of
spaces.
"""
struct UserExpr
    expr::String
    indentation::Int
end

"""
    code_block(s)

Wrap `s` in a Markdown code block.
Assumes that the language is Julia.
"""
code_block(s) = "```language-julia\n$s\n```\n"

"""
    output_block(s)

Wrap `s` in a Markdown code block with the language description "output".
"""
output_block(s) = "```output\n$s\n```\n"

"""
    CODEBLOCK_PATTERN

Pattern to match `jl` code blocks.

This pattern also, wrongly, matches blocks indented with four spaces.
These are ignored after matching.
"""
const CODEBLOCK_PATTERN = r"```jl\s*([^```]*)\n([ ]*)```\n"

const INLINE_CODEBLOCK_PATTERN = r" `jl ([^`]*)`"

extract_expr_example() = """
    lorem
    ```jl
    foo(3)
    ```
       ```jl
       foo(3)
       bar
       ```
    ipsum `jl bar()` dolar
    """

"""
    extract_expr(s::AbstractString)::Vector

Return the contents of the `jl` code blocks.
Here, `s` is the contents of a Markdown file.

```jldoctest
julia> s = Books.extract_expr_example();

julia> Books.extract_expr(s)
3-element Vector{Books.UserExpr}:
 Books.UserExpr("foo(3)", 0)
 Books.UserExpr("foo(3)\\n   bar", 3)
 Books.UserExpr("bar()", 0)
```
"""
function extract_expr(s::AbstractString)::Vector
    matches = eachmatch(CODEBLOCK_PATTERN, s)
    function clean(m)
        expr = m[1]::SubString{String}
        expr = strip(expr)
        expr = string(expr)::String
        indentation = if haskey(m, 2)
            spaces = m[2]::SubString{String}
            length(spaces)
        else
            0
        end
        return UserExpr(expr, indentation)
    end
    from_codeblocks = clean.(matches)
    # These blocks are used in the Books.jl documentation.
    filter!(e -> e.indentation != 4, from_codeblocks)

    matches = eachmatch(INLINE_CODEBLOCK_PATTERN, s)
    from_inline = clean.(matches)
    exprs = [from_codeblocks; from_inline]

    function check_parse_errors(expr)
        try
            Meta.parse("begin $expr end")
        catch e
            error("Exception occured when trying to parse `$expr`")
        end
    end
    check_parse_errors.(exprs)
    return exprs
end

_remove_modules(expr::AbstractString) = replace(expr, r"^[A-Z][a-zA-Z]*\." => "")

"""
    method_name(expr::String)

Return file name for `expr`.
This is used for things like how to call an image file and a caption.

# Examples
```jldoctest
julia> Books.method_name("@some_macro(foo)")
"foo"

julia> Books.method_name("foo()")
"foo"

julia> Books.method_name("foo(3)")
"foo_3"

julia> Books.method_name("Options(foo(); caption='b')")
"Options_foo__captionis-b-"
```
"""
function method_name(expr::String)
    remove_macros(expr) = replace(expr, r"@[\w\_]*" => "")
    expr = remove_macros(expr)
    if startswith(expr, '(')
        expr = strip(expr, ['(', ')'])
    end
    expr = _remove_modules(expr)
    expr = replace(expr, '(' => '_')
    expr = replace(expr, ')' => "")
    expr = replace(expr, ';' => "_")
    expr = replace(expr, " " => "")
    expr = replace(expr, '"' => "-")
    expr = replace(expr, '\'' => "-")
    expr = replace(expr, '=' => "is")
    expr = replace(expr, '.' => "")
    expr = strip(expr, '_')
end

"""
    escape_expr(expr::AbstractString)

Escape an expression to the corresponding path.
The logic in this method should match the logic in the Lua filter.
"""
function escape_expr(expr::AbstractString)
    n = 80
    escaped = n < length(expr) ? expr[1:n] : expr
    escaped = replace(escaped, r"([^a-zA-Z0-9]+)" => "_")
    joinpath(GENERATED_DIR, "$escaped.md")
end

"""
    newlines(out::AbstractString) -> String

Add some extra newlines around the output.
This is required by Pandoc in some cases to parse the output correctly.
"""
newlines(out::AbstractString) = string('\n', out, '\n')::String

function evaluate_and_write(M::Module, userexpr::UserExpr)
    expr = userexpr.expr
    path = escape_expr(expr)
    expr_info = replace(expr, '\n' => "\\n")

    ex = Meta.parse("begin $expr end")
    out = Core.eval(Main, ex)
    markdown = newlines(convert_output(expr, path, out))
    indent = userexpr.indentation
    if 0 < indent
        lines = split(markdown, '\n')
        spaces = join(repeat([" "], indent))
        lines = spaces .* lines
        markdown = join(lines, '\n')
    end
    write(path, markdown)
    return nothing
end

function evaluate_and_write(f::Function)
    function_name = Base.nameof(f)
    expr = "$(function_name)()"
    path = escape_expr(expr)
    expr_info = replace(expr, '\n' => "\\n")
    out = f()
    converted = newlines(convert_output(expr, path, out))
    write(path, converted)
    return nothing
end

function clean_stacktrace(stacktrace::String)
    lines = split(stacktrace, '\n')
    contains_books = [contains(l, "] top-level scope") for l in lines]
    i = findfirst(contains_books)
    lines = lines[1:i+5]
    lines = [lines; " [...]"]
    stacktrace = join(lines, '\n')
end

function report_error(userexpr::UserExpr, e, callpath::String, block_number::Int)
    expr = userexpr.expr
    path = escape_expr(expr)
    # Source: Franklin.jl/src/eval/run.jl.
    if VERSION >= v"1.7.0-"
        exc, bt = last(Base.current_exceptions())
    else
        exc, bt = last(Base.catch_stack())
    end
    stacktrace = sprint(Base.showerror, exc, bt)::String
    stacktrace = clean_stacktrace(stacktrace)
    msg = """
        Failed to run block $block_number in "$callpath".
        Code:
        $expr

        Details:
        $stacktrace
        """
    @error msg
    write(path, code_block(msg))
end

"""
    evaluate_include(expr::UserExpr, fail_on_error::Bool, callpath::String, block_number::Int)

For a `path` included in a Markdown file, run the corresponding function and write the output to `path`.
"""
function evaluate_include(
        userexpr::UserExpr,
        fail_on_error::Bool,
        callpath::String,
        block_number::Int
    )
    if fail_on_error
        evaluate_and_write(Main, userexpr)
    else
        try
            return evaluate_and_write(Main, userexpr)
        catch e
            # Newline to be placed behind the ProgressMeter output.
            println()
            if e isa InterruptException
                @info "Process was stopped by a terminal interrupt (CTRL+C)"
                return e
            end
            report_error(userexpr, e, callpath, block_number)
            return CapturedException(e, catch_backtrace())
        end
    end
end

"""
    expand_path(p)

Expand path to allow an user to pass `index` instead of `contents/index.md` to `gen`.
Not allowing `index.md` because that is confusing with entr(f, ["contents"], M).
"""
function expand_path(p)
    joinpath("contents", "$p.md")
end

function _included_expressions(paths)
    paths = [contains(dirname(p), "contents") ? p : expand_path(p) for p in paths]
    exprs = NamedTuple{(:path, :userexpr, :block_number), Tuple{String, UserExpr, Int}}[]
    for path in paths
        block_number = 1
        extracted_exprs = extract_expr(read(path, String))
        for userexpr in extracted_exprs
            push!(exprs, (; path, userexpr, block_number))
            block_number += 1
        end
    end
    return exprs
end

function _callpath(path)
    @assert startswith(path, "contents/")
    return string(path[10:end])::String
end

"""
    gen(
        [paths::Vector{String}],
        [block_number::Union{Nothing,Int}=nothing];
        call_html::Bool=true,
        fail_on_error::Bool=false,
        project="default",
        kwargs...
    )

Populate the files in `$(Books.GENERATED_DIR)/` by calling the required methods.
These methods are specified by the filename and will output to that filename.
This allows the user to easily link code blocks to code.
After calling the methods, this method will also call `html()` to update the site when
`call_html == true`.
The `kwargs...` is meant to ignore `M` so that `entr_gen` is a drop-in replacement for `gen`.
"""
function gen(
        paths::Vector{String},
        block_number::Union{Nothing,Int}=nothing;
        call_html::Bool=true,
        fail_on_error::Bool=false,
        project="default",
        kwargs...
    )

    mkpath(GENERATED_DIR)
    exprs = _included_expressions(paths)
    if !isnothing(block_number)
        if length(paths) != 1
            @error "Expected length of `paths` to be 1 when using `block_number`."
        end
        path = only(paths)
        _filename(path) = splitext(_callpath(path))[1]
        filter!(e -> _filename(e.path) == path && e.block_number == block_number, exprs)
    end

    n = length(exprs)
    n == 0 && return nothing
    dt = 0.5
    p = ProgressMeter.ProgressUnknown(; dt, output=stdout)
    p.tlast = p.tlast - dt
    for i in 1:n
        path, userexpr, block_number = exprs[i]
        callpath = _callpath(path)
        showvalues = [
            (:path, callpath),
            (:block_number, "$block_number ($i / $n)"),
            (:expr, replace(userexpr.expr, '\n' => ' ')),
        ]
        # Using update to enforce seeing the progress at the first iteration.
        p.counter = i
        ProgressMeter.update!(p; showvalues)
        out = evaluate_include(userexpr, fail_on_error, callpath, block_number)
        if out isa CapturedException
            filename, _ = splitext(callpath)
            @info """To re-run the code block that threw the error, use
                gen("$filename", $block_number; kwargs...)
                """
            return nothing
        end
        if out isa InterruptException
            return nothing
        end
    end
    ProgressMeter.finish!(p)
    if call_html
        @info "Updating html"
        try
            html(; project)
        catch e
            if e isa InterruptException
                return nothing
            else
                @error "Failed to update HTML" exception=(e, catch_backtrace())
            end
        end
    end
    return nothing
end

function gen(;
        call_html::Bool=true,
        fail_on_error::Bool=false,
        project="default",
        kwargs...
    )
    if !isfile("config.toml")
        error("Couldn't find `config.toml`. Is there a valid project in $(pwd())?")
    end
    paths = inputs(project)
    gen(paths; fail_on_error, project, call_html)
end

"""
    gen(path::AbstractString, [block_number]; kwargs...)

Convenience method for passing `path::AbstractString` instead of `paths::Vector`.
"""
function gen(path::AbstractString, block_number::Union{Nothing,Int}=nothing; kwargs...)
    path = string(path)::String
    return gen([path], block_number; kwargs...)
end
precompile(gen, (String,))

"""
    entr_gen(path::AbstractString, [block_number]; M=[], kwargs...)

Execute `gen(path, [block_number]; M, kwargs...)` whenever files in `contents` or code in
one of the modules `M` changes.
This is a convenience function around `Revise.entr(() -> gen(...), ["contents"], M)`.
"""
function entr_gen(path::AbstractString, block_number=nothing; M=[], kwargs...)
    entr(["contents"], M) do
        gen(path, block_number; kwargs...)
    end
end
