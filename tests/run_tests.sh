#!/bin/bash
# =============================================================================
# tests/run_tests.sh — Build and run the MPI test suite
#
# Usage:
#   ./run_tests.sh [OPTIONS]
#
# Options:
#   --ompi-prefix=PATH   OpenMPI install prefix (auto-detected if not given)
#   --np=N               Number of MPI ranks (default: 4)
#   --nodes=N            Number of nodes for srun (default: 1)
#   --launcher=auto|mpirun|srun   Force a specific launcher (default: auto)
#   --perf               Include latency/bandwidth measurements
#   --verbose            Verbose test output
#   --no-color           Disable ANSI colour output
#   --keep               Keep compiled binary after run
#   -h, --help           Show this help
#
# Environment:
#   OMPI_PREFIX          Override OpenMPI prefix detection
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_SRC="$SCRIPT_DIR/mpi_test_suite.c"
BINARY="$SCRIPT_DIR/mpi_test_suite.x"

# ---- Defaults ----
OMPI_PREFIX="${OMPI_PREFIX:-}"
NP=4
NODES=1
LAUNCHER="auto"
EXTRA_ARGS=""
KEEP=0

# ---- Colours ----
if [[ -t 1 ]]; then
    C_GREEN='\033[1;32m'; C_RED='\033[1;31m'
    C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_RESET='\033[0m'
else
    C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''; C_RESET=''
fi

log()  { echo -e "${C_CYAN}[test]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[ ok ]${C_RESET} $*"; }
fail() { echo -e "${C_RED}[fail]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[warn]${C_RESET} $*" >&2; }
die()  { echo -e "${C_RED}[err ]${C_RESET} $*" >&2; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^# ====/{ /^# ====/d; s/^# \{0,3\}//; p }' "$0"
    exit 0
}

# ---- Argument parsing ----
for arg in "$@"; do
    case "$arg" in
    --ompi-prefix=*) OMPI_PREFIX="${arg#--ompi-prefix=}" ;;
    --np=*)          NP="${arg#--np=}" ;;
    --nodes=*)       NODES="${arg#--nodes=}" ;;
    --launcher=*)    LAUNCHER="${arg#--launcher=}" ;;
    --perf)          EXTRA_ARGS="$EXTRA_ARGS --perf" ;;
    --verbose)       EXTRA_ARGS="$EXTRA_ARGS --verbose" ;;
    --no-color)      C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''; C_RESET='' ;;
    --keep)          KEEP=1 ;;
    -h|--help)       usage ;;
    *) die "Unknown argument: $arg" ;;
    esac
done

# ---- Locate OpenMPI ----
find_ompi_prefix() {
    # 1. Explicit env var
    [[ -n "$OMPI_PREFIX" ]] && { printf '%s\n' "$OMPI_PREFIX"; return 0; }
    # 2. mpicc in PATH
    local mpicc
    if mpicc=$(command -v mpicc 2>/dev/null); then
        printf '%s\n' "$(dirname "$(dirname "$mpicc")")"
        return 0
    fi
    return 1
}

if ! OMPI_PREFIX=$(find_ompi_prefix); then
    die "Cannot find OpenMPI. Set --ompi-prefix=PATH or add mpicc to PATH"
fi

MPICC="$OMPI_PREFIX/bin/mpicc"
MPIRUN="$OMPI_PREFIX/bin/mpirun"

[[ -x "$MPICC"   ]] || die "mpicc not found at $MPICC"
[[ -f "$SUITE_SRC" ]] || die "Test source not found: $SUITE_SRC"

# ---- Launcher selection ----
pick_launcher() {
    case "$LAUNCHER" in
    mpirun) echo "mpirun" ;;
    srun)   echo "srun" ;;
    auto)
        # Inside a Slurm allocation? Use srun.
        if [[ -n "${SLURM_JOB_ID:-}" ]] && command -v srun >/dev/null 2>&1; then
            echo "srun"
        else
            echo "mpirun"
        fi
        ;;
    *) die "Unknown launcher: $LAUNCHER" ;;
    esac
}
LAUNCHER_CMD=$(pick_launcher)

# ---- Build ----
log "OpenMPI prefix : $OMPI_PREFIX"
log "Compiler       : $MPICC"
log "Launcher       : $LAUNCHER_CMD"
log "Ranks          : $NP"
log "Nodes          : $NODES"
echo ""

log "Compiling $SUITE_SRC ..."
"$MPICC" -O2 -o "$BINARY" "$SUITE_SRC" -lm \
    || die "Compilation failed"
ok "Compiled → $BINARY"

# ---- Check dependencies ----
log "Checking library dependencies..."
if ldd "$BINARY" | grep -q "not found"; then
    warn "Missing libraries detected:"
    ldd "$BINARY" | grep "not found" | sed 's/^/    /' >&2
    warn "Set LD_LIBRARY_PATH to include your OpenMPI/UCX/UCC/compiler libs"
fi

# ---- Run ----
echo ""
log "Running MPI test suite..."
echo ""

LAUNCH_FAILED=0

if [[ "$LAUNCHER_CMD" == "srun" ]]; then
    srun --mpi=pmix \
         -N "$NODES" \
         -n "$NP" \
         "$BINARY" $EXTRA_ARGS \
    || LAUNCH_FAILED=1
else
    "$MPIRUN" \
        -np "$NP" \
        --map-by node \
        --mca mca_base_component_path "$OMPI_PREFIX/lib/openmpi" \
        -x UCX_WARN_UNUSED_ENV_VARS=n \
        "$BINARY" $EXTRA_ARGS \
    || LAUNCH_FAILED=1
fi

echo ""
if [[ $LAUNCH_FAILED -eq 0 ]]; then
    ok "Test suite exited cleanly (exit code 0)"
else
    fail "Test suite reported failures or crashed (non-zero exit)"
fi

# ---- Cleanup ----
if [[ $KEEP -eq 0 ]]; then
    rm -f "$BINARY"
    log "Binary removed (use --keep to retain)"
fi

exit $LAUNCH_FAILED
