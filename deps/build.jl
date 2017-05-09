using Compat
using BinDeps

const CXXWRAP_JL_VERSION = v"0.3.1"

function prompt_cmake()
  try
    run(pipeline(`cmake --version`, stdout=DevNull, stderr=DevNull))
    return
  catch
    error("command \"cmake\" not found in path, please install CMake and make sure it can be found")
  end
end

@static if is_windows()
  # prefer building if requested
  if haskey(ENV, "BUILD_ON_WINDOWS") && ENV["BUILD_ON_WINDOWS"] == "1"
    prompt_cmake()
    saved_defaults = deepcopy(BinDeps.defaults)
    empty!(BinDeps.defaults)
    append!(BinDeps.defaults, [BuildProcess])
  end
else
  prompt_cmake()
end


@BinDeps.setup

build_type = get(ENV, "CXXWRAP_BUILD_TYPE", "Release")

libname = build_type == "Debug" ? "libjulia-debug" : "libjulia"

# The base library, needed to wrap functions
cxx_wrap = library_dependency("cxx_wrap", aliases=["libcxx_wrap"])

prefix = joinpath(BinDeps.depsdir(cxx_wrap), "usr")

@static if is_windows()
    bindir = joinpath(prefix, "bin")
else
    bindir = joinpath(prefix, "lib"*(Sys.WORD_SIZE == 64 && !is_apple() ? "64" : ""))
end

cxx_wrap_srcdir = joinpath(BinDeps.depsdir(cxx_wrap), "src", "cxx_wrap")
cxx_wrap_builddir = joinpath(BinDeps.depsdir(cxx_wrap), "builds", "cxx_wrap")
lib_prefix = @static is_windows() ? "" : "lib"
lib_suffix = @static is_windows() ? "dll" : (@static is_apple() ? "dylib" : "so")
julia_base_dir = splitdir(JULIA_HOME)[1]
julia_executable = split(string(Base.julia_cmd()))[1][2:end]

makeopts = ["--", "-j", "$(Sys.ARCH == :armv7l ? 2 : Sys.CPU_CORES+2)"]

# Set generator if on windows
genopt = "Unix Makefiles"
@static if is_windows()
  if isdir(prefix)
    rm(prefix, recursive=true)
  end
  if get(ENV, "MSYSTEM", "") == ""
    makeopts = "--"
    if Sys.WORD_SIZE == 64
      genopt = "Visual Studio 14 2015 Win64"
    else
      genopt = "Visual Studio 14 2015"
    end
  else
    lib_prefix = "lib" #Makefiles on windows do keep the lib prefix
  end
end

# Functions library for testing
example_labels = [:cxxwrap_containers, :except, :extended, :functions, :hello, :inheritance, :parametric, :types]
examples = BinDeps.LibraryDependency[]
for l in example_labels
  @eval $l = $(library_dependency(string(l), aliases=["lib"*string(l)]))
  push!(examples, eval(:($l)))
end
examples_srcdir = joinpath(BinDeps.depsdir(functions), "src", "examples")
examples_builddir = joinpath(BinDeps.depsdir(functions), "builds", "examples")
deps = [cxx_wrap; examples]

cxx_steps = @build_steps begin
  `cmake -G "$genopt" -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_BUILD_TYPE="$build_type" -DCMAKE_PROGRAM_PATH=$JULIA_HOME $cxx_wrap_srcdir`
  `cmake --build . --config $build_type --target install $makeopts`
end

example_paths = AbstractString[]
for l in example_labels
  push!(example_paths, joinpath(bindir, "$(lib_prefix)$(string(l)).$lib_suffix"))
end

examples_steps = @build_steps begin
  `cmake -G "$genopt" -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_BUILD_TYPE="$build_type" -DCMAKE_PROGRAM_PATH=$JULIA_HOME $examples_srcdir`
  `cmake --build . --config $build_type --target install $makeopts`
end

# If built, always run cmake, in case the code changed
if isdir(cxx_wrap_builddir)
  BinDeps.run(@build_steps begin
    ChangeDirectory(cxx_wrap_builddir)
    cxx_steps
  end)
end
if isdir(examples_builddir)
  BinDeps.run(@build_steps begin
    ChangeDirectory(examples_builddir)
    examples_steps
  end)
end

provides(BuildProcess,
  (@build_steps begin
    CreateDirectory(cxx_wrap_builddir)
    @build_steps begin
      ChangeDirectory(cxx_wrap_builddir)
      FileRule(joinpath(bindir, "$(lib_prefix)cxx_wrap.$lib_suffix"), cxx_steps)
    end
  end), cxx_wrap)

provides(BuildProcess,
  (@build_steps begin
    CreateDirectory(examples_builddir)
    @build_steps begin
      ChangeDirectory(examples_builddir)
      FileRule(example_paths, examples_steps)
    end
  end), examples)

@static if is_windows()
  shortversion = "$(VERSION.major).$(VERSION.minor)"
  zipfilename = "CxxWrap-julia-$(shortversion)-win$(Sys.WORD_SIZE).zip"
  archname = Sys.WORD_SIZE == 64 ? "x64" : "x86"
  pkgverstring = string(CXXWRAP_JL_VERSION)
  if endswith(pkgverstring,"+")
    bin_uri = URI("https://ci.appveyor.com/api/projects/barche/cxxwrap-jl/artifacts/$(zipfilename)?job=Environment%3a+JULIAVERSION%3djulialang%2fbin%2fwinnt%2f$(archname)%2f$(shortversion)%2fjulia-$(shortversion)-latest-win$(Sys.WORD_SIZE).exe%2c+BUILD_ON_WINDOWS%3d1")
  else
    bin_uri = URI("https://github.com/JuliaInterop/CxxWrap.jl/releases/download/v$(pkgverstring)/CxxWrapv$(pkgverstring)-julia-$(VERSION.major).$(VERSION.minor)-win$(Sys.WORD_SIZE).zip")
  end
  provides(Binaries, Dict(bin_uri => deps), os = :Windows)
end

@BinDeps.install Dict([(:cxx_wrap, :_l_cxx_wrap),
                       (:cxxwrap_containers, :_l_containers),
                       (:except, :_l_except),
                       (:extended, :_l_extended),
                       (:functions, :_l_functions),
                       (:hello, :_l_hello),
                       (:inheritance, :_l_inheritance),
                       (:parametric, :_l_parametric),
                       (:types, :_l_types)])

@static if is_windows()
  if haskey(ENV, "BUILD_ON_WINDOWS") && ENV["BUILD_ON_WINDOWS"] == "1"
    empty!(BinDeps.defaults)
    append!(BinDeps.defaults, saved_defaults)
    if get(ENV, "MSYSTEM", "") == "MINGW32"
      run(`cp -f $(joinpath("/mingw32", "bin", "libwinpthread-1.dll")) $(bindir)`)
      run(`cp -f $(joinpath("/mingw32", "bin", "libgcc_s_dw2-1.dll")) $(bindir)`)
    else
      redist_dlls = ["concrt140.dll", "msvcp140.dll", "vccorlib140.dll", "vcruntime140.dll"]
      redistbasepath = "C:\\Program Files (x86)\\Microsoft Visual Studio 14.0\\VC\\redist\\$(Sys.WORD_SIZE == 64 ? "x64" : "x86")\\Microsoft.VC140.CRT"
      for dll in redist_dlls
        cp(joinpath(redistbasepath, dll), joinpath(bindir, dll), remove_destination=true)
      end
    end
  end
end
