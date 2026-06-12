#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

julia --startup-file=no -e "
    import Pkg
    Pkg.activate(temp=true)
    Pkg.add(\"JuliaFormatter\")
    using JuliaFormatter
    format(ARGS[1])
    println(\"format complete\")
" -- "$REPO_ROOT/src"
