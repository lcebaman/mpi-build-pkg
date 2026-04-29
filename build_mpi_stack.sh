#!/bin/bash
# =============================================================================
# build_mpi_stack.sh — Top-level MPI stack builder
#
# Builds: UCX → UCC → OpenMPI (with optional hcoll and CUDA support)
#
# Usage:
#   ./build_mpi_stack.sh [OPTIONS]
#
# Options:
#   --compiler=<name>          Compiler family: gcc | aocc | intel  (required)
#   --compiler-version=<ver>   Compiler version, e.g. 2025.2.1      (required)
#   --ompi-version=<ver>       OpenMPI version, e.g. 5.0.9          (required)
#   --ucx-version=<ver|system> UCX version, e.g. 1.20.0, or system (required)
#   --ucx=system               Alias for --ucx-version=system
#   --ucc-version=<ver>        UCC version, e.g. 1.3.0              (required)
#   --prefix=<path>            Installation root                     (required)
#   --with-hcoll[=<path>]      Enable hcoll (auto-detect or explicit path)
#   --without-hcoll            Disable hcoll (default)
#   --with-cuda[=<path>]       Enable CUDA support (auto-detect or explicit path)
#   --without-cuda             Disable CUDA support (default: auto-detect)
#   --with-gdrcopy[=<path>]    Enable GDRCopy (auto-detect or explicit path)
#   --module-root=<path>       Where to write Lmod .lua files (default: $PWD/modules)
#   --skip-ucx                 Skip UCX build (use existing install)
#   --skip-ucc                 Skip UCC build (use existing install)
#   --skip-ompi                Skip OpenMPI build
#   --dry-run                  Print configuration and exit without building
#   -h, --help                 Show this help
#
# Environment overrides:
#   CUDA_HOME / CUDA_ROOT      Override CUDA path detection
#   HCOLL_DIR                  Override hcoll path detection
#   NCCL_HOME                  Override NCCL path for UCC
#   UCXCUDAOPT                 Extra UCX CUDA configure args (space-separated)
#
# Examples:
#   # Intel + CUDA, no hcoll (recommended modern stack):
#   ./build_mpi_stack.sh \
#       --compiler=intel --compiler-version=2025.2.1 \
#       --ompi-version=5.0.9 --ucx-version=1.20.0 --ucc-version=1.3.0 \
#       --prefix=/hpc/base/swstack \
#       --with-cuda
#
#   # AOCC, no GPU, no hcoll:
#   ./build_mpi_stack.sh \
#       --compiler=aocc --compiler-version=5.0.0 \
#       --ompi-version=5.0.9 --ucx-version=1.20.0 --ucc-version=1.3.0 \
#       --prefix=/hpc/base/amd
#
#   # Intel + explicit hcoll from HPC-X (legacy clusters):
#   ./build_mpi_stack.sh \
#       --compiler=intel --compiler-version=2025.2.1 \
#       --ompi-version=5.0.9 --ucx-version=1.20.0 --ucc-version=1.3.0 \
#       --prefix=/hpc/base/swstack \
#       --with-hcoll=/opt/mellanox/hpc-x/hpc-x-v2.21/hcoll
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Source all library modules
source "$LIB_DIR/log.sh"
source "$LIB_DIR/detect.sh"
source "$LIB_DIR/modules_env.sh"
source "$LIB_DIR/build_ucx.sh"
source "$LIB_DIR/build_ucc.sh"
source "$LIB_DIR/build_ompi.sh"
source "$LIB_DIR/modulefile.sh"

# =============================================================================
# Defaults
# =============================================================================
COMPILER=""
COMPILER_VERSION=""
OMPI_VERSION=""
UCX_VERSION=""
UCX_SYSTEM=0
UCC_VERSION=""
PREFIX=""
MODULE_ROOT=""
HCOLL_MODE="no"          # no | auto | yes:<path>
CUDA_MODE="auto"         # no | auto | yes:<path>
GDRCOPY_MODE="auto"      # no | auto | yes:<path>
SKIP_UCX=0
SKIP_UCC=0
SKIP_OMPI=0
DRY_RUN=0

# =============================================================================
# Argument parsing
# =============================================================================
usage() {
    sed -n '/^# Usage:/,/^# ====/{ /^# ====/d; s/^# \{0,3\}//; p }' "$0"
    exit 0
}

for arg in "$@"; do
    case "$arg" in
    --compiler=*)          COMPILER="${arg#--compiler=}" ;;
    --compiler-version=*)  COMPILER_VERSION="${arg#--compiler-version=}" ;;
    --ompi-version=*)      OMPI_VERSION="${arg#--ompi-version=}" ;;
    --ucx-version=*)       UCX_VERSION="${arg#--ucx-version=}" ;;
    --ucx=system)          UCX_VERSION="system" ;;
    --ucc-version=*)       UCC_VERSION="${arg#--ucc-version=}" ;;
    --prefix=*)            PREFIX="${arg#--prefix=}" ;;
    --module-root=*)       MODULE_ROOT="${arg#--module-root=}" ;;
    --with-hcoll=*)        HCOLL_MODE="yes:${arg#--with-hcoll=}" ;;
    --with-hcoll)          HCOLL_MODE="auto" ;;
    --without-hcoll)       HCOLL_MODE="no" ;;
    --with-cuda=*)         CUDA_MODE="yes:${arg#--with-cuda=}" ;;
    --with-cuda)           CUDA_MODE="auto" ;;
    --without-cuda)        CUDA_MODE="no" ;;
    --with-gdrcopy=*)      GDRCOPY_MODE="yes:${arg#--with-gdrcopy=}" ;;
    --with-gdrcopy)        GDRCOPY_MODE="auto" ;;
    --without-gdrcopy)     GDRCOPY_MODE="no" ;;
    --skip-ucx)            SKIP_UCX=1 ;;
    --skip-ucc)            SKIP_UCC=1 ;;
    --skip-ompi)           SKIP_OMPI=1 ;;
    --dry-run)             DRY_RUN=1 ;;
    --list-compilers)
        source "$LIB_DIR/log.sh"
        source "$LIB_DIR/modules_env.sh"
        echo "Compilers defined in ${_COMPILERS_CONF:-compilers.conf}:"
        conf_list_compilers | sed 's/^/  /'
        exit 0
        ;;
    -h|--help)             usage ;;
    *) log_die "Unknown argument: $arg  (use --help)" ;;
    esac
done

# =============================================================================
# Validation
# =============================================================================
[[ -z "$COMPILER" ]]         && log_die "--compiler is required"
[[ -z "$COMPILER_VERSION" ]] && log_die "--compiler-version is required"
[[ -z "$OMPI_VERSION" ]]     && log_die "--ompi-version is required"
[[ -z "$UCX_VERSION" ]]      && log_die "--ucx-version is required"
[[ -z "$UCC_VERSION" ]]      && log_die "--ucc-version is required"
[[ -z "$PREFIX" ]]           && log_die "--prefix is required"

validate_version "$OMPI_VERSION" "OpenMPI"
if [[ "$UCX_VERSION" == "system" ]]; then
    UCX_SYSTEM=1
    SKIP_UCX=1
else
    validate_version "$UCX_VERSION"  "UCX"
fi
validate_version "$UCC_VERSION"  "UCC"

PREFIX="${PREFIX%/}"
MODULE_ROOT="${MODULE_ROOT:-$PWD/modules}"

# Install paths follow: $PREFIX/<pkg>/<version>/<compiler>/<compiler_version>
if [[ $UCX_SYSTEM -eq 1 ]]; then
    UCX_PREFIX="system"
else
    UCX_PREFIX="$PREFIX/ucx/$UCX_VERSION/$COMPILER/$COMPILER_VERSION"
fi
UCC_PREFIX="$PREFIX/ucc/$UCC_VERSION/$COMPILER/$COMPILER_VERSION"
OMPI_PREFIX="$PREFIX/openmpi/$OMPI_VERSION/$COMPILER/$COMPILER_VERSION"
OMPI_MODULE_UCX_ROOT="$UCX_PREFIX"
[[ $UCX_SYSTEM -eq 1 ]] && OMPI_MODULE_UCX_ROOT=""

# =============================================================================
# Print configuration summary
# =============================================================================
log_banner "MPI Stack Build Configuration"
log_kv "Compiler"         "$COMPILER $COMPILER_VERSION"
log_kv "OpenMPI"          "$OMPI_VERSION  →  $OMPI_PREFIX"
if [[ $UCX_SYSTEM -eq 1 ]]; then
    log_kv "UCX"              "system installed UCX"
else
    log_kv "UCX"              "$UCX_VERSION   →  $UCX_PREFIX"
fi
log_kv "UCC"              "$UCC_VERSION   →  $UCC_PREFIX"
log_kv "hcoll"            "$HCOLL_MODE"
log_kv "CUDA"             "$CUDA_MODE"
log_kv "GDRCopy"          "$GDRCOPY_MODE"
log_kv "Module root"      "$MODULE_ROOT"
log_kv "Skip UCX"         "$SKIP_UCX"
log_kv "Skip UCC"         "$SKIP_UCC"
log_kv "Skip OpenMPI"     "$SKIP_OMPI"

[[ $DRY_RUN -eq 1 ]] && { log_info "Dry run — exiting."; exit 0; }

# =============================================================================
# Load compiler modules
# =============================================================================
load_compiler_modules "$COMPILER" "$COMPILER_VERSION"

# =============================================================================
# Resolve optional features
# =============================================================================
CUDA_DIR=$(resolve_cuda   "$CUDA_MODE")    || true
GDRCOPY_DIR=$(resolve_gdrcopy "$GDRCOPY_MODE") || true
HCOLL_DIR=$(resolve_hcoll "$HCOLL_MODE")   || true

[[ -n "$CUDA_DIR"    ]] && log_info "CUDA:     $CUDA_DIR"
[[ -n "$GDRCOPY_DIR" ]] && log_info "GDRCopy:  $GDRCOPY_DIR"
[[ -n "$HCOLL_DIR"   ]] && log_info "hcoll:    $HCOLL_DIR"

# =============================================================================
# Build
# =============================================================================
START_TOTAL=$SECONDS

if [[ $SKIP_UCX -eq 0 ]]; then
    log_step "Building UCX $UCX_VERSION"
    mkdir -p "$UCX_PREFIX"
    ucx_download "$UCX_VERSION"
    ucx_build    "$UCX_VERSION" "$UCX_PREFIX" "$CUDA_DIR" "$GDRCOPY_DIR"
    generate_module "ucx" "$UCX_VERSION" "$UCX_PREFIX" \
        "$COMPILER" "$COMPILER_VERSION" "$MODULE_ROOT"
    log_ok "UCX done  ($(elapsed $START_TOTAL)s total)"
else
    if [[ $UCX_SYSTEM -eq 1 ]]; then
        log_info "Skipping UCX build — using system installed UCX"
    else
        log_info "Skipping UCX build — using $UCX_PREFIX"
    fi
fi

T_UCC=$SECONDS
if [[ $SKIP_UCC -eq 0 ]]; then
    log_step "Building UCC $UCC_VERSION"
    mkdir -p "$UCC_PREFIX"
    ucc_download "$UCC_VERSION"
    ucc_build    "$UCC_VERSION" "$UCC_PREFIX" "$UCX_PREFIX" "$CUDA_DIR"
    generate_module "ucc" "$UCC_VERSION" "$UCC_PREFIX" \
        "$COMPILER" "$COMPILER_VERSION" "$MODULE_ROOT"
    log_ok "UCC done  ($(elapsed $T_UCC)s)"
else
    log_info "Skipping UCC build — using $UCC_PREFIX"
fi

T_OMPI=$SECONDS
if [[ $SKIP_OMPI -eq 0 ]]; then
    log_step "Building OpenMPI $OMPI_VERSION"
    mkdir -p "$OMPI_PREFIX"
    ompi_download "$OMPI_VERSION"
    ompi_build    "$OMPI_VERSION" "$OMPI_PREFIX" \
        "$UCX_PREFIX" "$UCC_PREFIX" \
        "$HCOLL_MODE" "$HCOLL_DIR" \
        "$CUDA_DIR"
    generate_module "openmpi" "$OMPI_VERSION" "$OMPI_PREFIX" \
        "$COMPILER" "$COMPILER_VERSION" "$MODULE_ROOT" \
        "$OMPI_MODULE_UCX_ROOT" "$UCC_PREFIX" "$HCOLL_DIR"
    log_ok "OpenMPI done  ($(elapsed $T_OMPI)s)"
else
    log_info "Skipping OpenMPI build"
fi

log_banner "Build complete  (total: $(elapsed $START_TOTAL)s)"
log_info "Modules written to: $MODULE_ROOT"
log_info "Load with:  module use $MODULE_ROOT && module load openmpi/$OMPI_VERSION/$COMPILER/$COMPILER_VERSION"
