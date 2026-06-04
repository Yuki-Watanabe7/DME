#!/usr/bin/env bash
set -euo pipefail
julia --project=. -e 'using Pkg; Pkg.test()'