const crossref_bin = string(pandoc_crossref_path)::String
const crossref = "--filter=$crossref_bin"
const include_lua_filter = joinpath(PKGDIR, "src", "include-codeblocks.lua")
const include_files = "--lua-filter=$include_lua_filter"
const citeproc = "--citeproc"

function pandoc_file(filename)
    user_path = joinpath("pandoc", filename)
    fallback_path = joinpath(PKGDIR, "defaults", filename)
    isfile(user_path) ? user_path : fallback_path
end

function csl()
    csl_path = pandoc_file("style.csl")
    csl = "--csl=$csl_path"
end

extra_args = [
    "--number-sections",
    "--top-level-division=chapter"
]

function inputs(project)
    H = config(project, "homepage_contents")::String
    C = config(project, "contents")::Vector{String}
    names = [H; C]
    return [joinpath("contents", "$name.md") for name in names]
end

"""
    copy_extra_directory(dir)

Copy an extra directory such as "images" into build.
"""
function copy_extra_directory(dir)
    if !isdir(dir)
        error("Couldn't find `$(dir)` even though it was listed in `extra_directories`")
    end
    from = dir
    to = joinpath(BUILD_DIR, dir)
    cp(from, to; force=true)
end

"""
    copy_extra_directories(project)

Copy the extra directories defined for `project`.
"""
function copy_extra_directories(project)
    extra_directories = config(project, "extra_directories")::Vector
    copy_extra_directory.(extra_directories)
end

function call_pandoc(args)::Tuple{Base.Process, String}
    pandoc() do pandoc_bin
        cmd = `$pandoc_bin $args`
        stdout = IOBuffer()
        p = run(pipeline(cmd; stdout))
        out = String(take!(stdout))::String
        return (p, out)
    end
end

function copy_css()
    filename = "style.css"
    css_path = pandoc_file(filename)
    cp(css_path, joinpath(BUILD_DIR, filename); force=true)
end

@memoize function is_mousetrap_enabled()::Bool
    meta = default_metadata()::Dict
    if "mousetrap" in keys(meta)
        meta["mousetrap"]::Bool
    else
        false
    end
end

@memoize function copy_mousetrap()
    if is_mousetrap_enabled()
        filename = "mousetrap.min.js"
        from = pandoc_file(filename)
        cp(from, joinpath(BUILD_DIR, filename); force=true)
    end
end

@memoize function copy_juliamono()
    filename = "JuliaMono-Regular.woff2"
    from_path = joinpath(juliamono_dir(), "webfonts", filename)
    cp(from_path, joinpath(BUILD_DIR, filename); force=true)
end

function codeblock2output(s::AbstractString)
    expr = s
    # Hacky way to ignore code blocks with four spaces.
    # Cleaner would be to improve the regex.
    if endswith(s, "\n    ```\n")
        return s
    end
    expr = strip(expr)
    # Remove start and end of code block.
    expr = expr[7:end-4]
    expr = strip(expr)
    output_path = escape_expr(expr)
    if isfile(output_path)
        output = read(output_path, String)
        # The indentation of the first line is already handled somewhere else
        # (probably by the regex).
        output = lstrip(output)
        return output * '\n'
    else
        msg = """
            Cannot find file at $output_path for $expr.
            Did you run `gen()` when having loaded your module?
            """
        return code_block(msg)
    end
end

function inlinecodeblock2output(s::AbstractString)
    expr = strip(s)
    # Remove _jl prefix
    expr = expr[4:end-1]
    expr = strip(expr)
    output_path = escape_expr(expr)
    if isfile(output_path)
        output = read(output_path, String)
        output = strip(output)
        return ' ' * output
    else
        msg = """
            Cannot find file at $output_path for $expr.
            Did you run `gen()` when having loaded your module?
            """
        return code_block(msg)
    end
end

"""
    embed_output(text::String)

In a Markdown string containing `jl` code blocks, embed the output from the output path.
"""
function embed_output(text::String)
    text = replace(text, CODEBLOCK_PATTERN => codeblock2output)
    text = replace(text, INLINE_CODEBLOCK_PATTERN => inlinecodeblock2output)
    return text
end

"""
    write_input_markdown(project; skip_index=false)::String

Combine all the `contents/` files and embed the outputs into one Markdown file.
Return the path of the Markdown file.
"""
function write_input_markdown(project; skip_index=false)::String
    files = inputs(project)
    if skip_index
        files = files[2:end]
    end
    texts = read.(files, String)
    texts = embed_output.(texts)
    # Double newline to make parsing easier for Pandoc (Books issue #295).
    text = join(texts, "\n\n")
    dir = Books.GENERATED_DIR
    if !isdir(dir)
        @warn "$(dir) directory doesn't exist. Did you run `gen()`?"
        mkpath(dir)
    end
    markdown_path = joinpath(dir, "input.md")
    write(markdown_path, text)
    return markdown_path
end

function verify_cross_references(h)
    # For example, "<strong>¿sec:about?</strong>"
    if contains(h, "<strong>¿")
        rx = r"<strong>¿([^<]*)\?</strong>"
        matches = collect(eachmatch(rx, h))
        refs = ["- " * m[1] for m in matches]
        missing_crossrefs = join(refs, "\n")
        error("Output contains undefined cross-references:\n\n$missing_crossrefs\n")
    end
end

function _pandoc_html(project::AbstractString, url_prefix::AbstractString; fail_on_error=false)
    input_path = write_input_markdown(project)
    copy_extra_directories(project)
    html_template_path = pandoc_file("template.html")
    template = "--template=$html_template_path"
    output_filename = joinpath(BUILD_DIR, "index.html")
    output = "--output=$output_filename"
    metadata_path = combined_metadata_path(project)
    metadata = "--metadata-file=$metadata_path"
    copy_css()
    copy_mousetrap()
    copy_juliamono()

    args = String[
        input_path;
        crossref;
        citeproc;
        "--mathjax";
        # Using highlight.js instead of the Pandoc built-in highlighter.
        "--no-highlight";
        csl();
        metadata;
        template;
        extra_args;
        # The url_prefix is either "" or startswith '/'.
        "--variable=url-prefix:$url_prefix";
        # output
    ]
    _, out = call_pandoc(args)
    if fail_on_error
        verify_cross_references(out)
    end
    return out
end

"""
    ci_url_prefix(project)

Return the url prefix when `is_ci() == true`.

# Example
```jldoctest
julia> docs_dir = joinpath(pkgdir(Books), "docs");

julia> cd(docs_dir) do
           Books.ci_url_prefix("default")
       end
"/Books.jl"

julia> cd(docs_dir) do
           Books.ci_url_prefix("test")
       end
"/Example.jl"
```
"""
function ci_url_prefix(project)
    user_setting = config(project, "online_url_prefix")
    if !startswith(user_setting, '/') && user_setting != ""
        user_setting = '/' * user_setting
    end
    return user_setting
end

@memoize function highlight(url_prefix)
    highlight_dir = joinpath(Artifacts.artifact"Highlight", "cdn-release-11.5.0")

    highlight_name = "highlight.min.js"
    highlight_path = joinpath(highlight_dir, "build", highlight_name)
    cp(highlight_path, joinpath(BUILD_DIR, highlight_name); force=true)

    julia_highlight_name = "julia.min.js"
    julia_highlight_path = joinpath(highlight_dir, "build", "languages", julia_highlight_name)
    cp(julia_highlight_path, joinpath(BUILD_DIR, julia_highlight_name); force=true)

    style_name = "github.min.css"
    style_path = joinpath(highlight_dir, "build", "styles", style_name)
    cp(style_path, joinpath(BUILD_DIR, style_name); force=true)

    # Don't add `url_prefix` to the stylesheet link. It will be handled by `fix_links`.
    """
    <link rel="stylesheet" href="/$style_name">
    <script src="$url_prefix/$highlight_name"></script>
    <script src="$url_prefix/$julia_highlight_name"></script>
    <script>
    document.addEventListener('DOMContentLoaded', (event) => {
        document.querySelectorAll('pre').forEach((el) => {
            if (!el.classList.contains('output')) {
                hljs.highlightElement(el);
            }
        });
    });
    </script>
    """
end

function html(; project="default", extra_head="", fail_on_error=false, build_sitemap=false)
    copy_extra_directories(project)
    url_prefix = is_ci() ? ci_url_prefix(project)::String : ""
    c = config(project, "contents")
    if config(project, "highlight")::Bool
        extra_head = extra_head * highlight(url_prefix)
    end
    h = _pandoc_html(project, url_prefix; fail_on_error)
    if build_sitemap
        sitemap(project, h)
    end
    return write_html_pages(url_prefix, h, extra_head)
end

"""
    ignore_homepage(project, input_paths)

By default, the homepage is only shown to website visitors.
However, the user can show the homepage also to offline visitors via the configuration option.
"""
function ignore_homepage(project, input_paths)
    c = config(project)
    override::Bool = config(project, "include_homepage_outside_html")
    return override ? input_paths : input_paths[2:end]
end

function juliamono_dir()
    artifact = Artifacts.artifact"JuliaMono"
    return joinpath(artifact, "juliamono-$JULIAMONO_VERSION")
end

function pdf(; project="default")
    input_path = write_input_markdown(project; skip_index=true)
    copy_extra_directories(project)
    latex_template_path = pandoc_file("template.tex")
    template = "--template=$latex_template_path"
    file = config(project, "output_filename")
    output_filename = joinpath(BUILD_DIR, "$file.pdf")
    output = "--output=$output_filename"
    metadata_path = combined_metadata_path(project)
    metadata = "--metadata-file=$metadata_path"
    output_block_filter = joinpath(PKGDIR, "src", "output-block.lua")
    input_files = ignore_homepage(project, inputs(project))
    listings_unicode_path = joinpath(PKGDIR, "defaults", "julia_listings_unicode.tex")
    listings_path = joinpath(PKGDIR, "defaults", "julia_listings.tex")

    tectonic() do tectonic_bin
        pdf_engine = "--pdf-engine=$tectonic_bin"

        args = [
            input_path;
            crossref;
            citeproc;
            csl();
            metadata;
            template;
            "--lua-filter=$output_block_filter";
            "--listings";
            pdf_engine;
            # Print engine info. Extremely useful for debugging.
            "--pdf-engine-opt=--print";
            "--variable=listings-unicode-path:$listings_unicode_path";
            "--variable=listings-path:$listings_path";
            "--variable=juliamono-dir:$(juliamono_dir())";
            "--variable=build-info:$(today())";
            extra_args
        ]

        output_tex_filename = joinpath(BUILD_DIR, "$file.tex")
        tex_output = "--output=$output_tex_filename"
        call_pandoc([args; tex_output])
        @info "Wrote $output_tex_filename (for debugging purposes)"

        out = call_pandoc([args; output])

        if !isnothing(out)
            println("Built $output_filename")
        end
    end

    return nothing
end

"""
    cleanup()

Remove generated files.
"""
function cleanup()
    dirs = [Books.GENERATED_DIR, Books.BUILD_DIR]
    for dir in dirs
        rm(dir; force=true, recursive=true)
        mkpath(dir)
    end
end

function build_all(; project="default", extra_head="", fail_on_error=false)
    mkpath(BUILD_DIR)
    filename = "favicon.png"
    from_path = joinpath("pandoc", filename)
    if isfile(from_path)
        cp(from_path, joinpath(BUILD_DIR, filename); force=true)
    end
    build_sitemap = true
    html(; project, extra_head, fail_on_error, build_sitemap)
    write_extra_html_files(project)
    pdf(; project)
    return nothing
end
