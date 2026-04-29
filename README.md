# mpi-build-pkg

Build UCX + UCC + OpenMPI as a coherent stack, with optional CUDA and hcoll support.

## Package layout

```
mpi-build-pkg/
├── build_mpi_stack.sh      ← main entry point
└── lib/
    ├── log.sh              ← coloured logging helpers
    ├── detect.sh           ← CUDA / GDRCopy / hcoll / NCCL / knem detection
    ├── modules_env.sh      ← compiler module loading (Lmod)
    ├── build_ucx.sh        ← UCX download + configure + build
    ├── build_ucc.sh        ← UCC download + configure + build
    ├── build_ompi.sh       ← OpenMPI download + configure + build
    └── modulefile.sh       ← Lmod .lua file generator
```

## Quick start

```bash
# Recommended modern stack — Intel compiler, CUDA auto-detected, no hcoll
./build_mpi_stack.sh \
    --compiler=intel --compiler-version=2025.2.1 \
    --ompi-version=5.0.9 --ucx-version=1.20.0 --ucc-version=1.3.0 \
    --prefix=/hpc/base/swstack \
    --with-cuda

# AOCC, no GPU
./build_mpi_stack.sh \
    --compiler=aocc --compiler-version=5.0.0 \
    --ompi-version=5.0.9 --ucx-version=1.20.0 --ucc-version=1.3.0 \
    --prefix=/hpc/base/amd

# Use UCX from the system compiler/library search paths
./build_mpi_stack.sh \
    --compiler=gcc --compiler-version=13.2.0 \
    --ompi-version=5.0.9 --ucx-version=system --ucc-version=1.3.0 \
    --prefix=/hpc/base/swstack

# Legacy cluster with hcoll from HPC-X
./build_mpi_stack.sh \
    --compiler=intel --compiler-version=2025.2.1 \
    --ompi-version=5.0.9 --ucx-version=1.20.0 --ucc-version=1.3.0 \
    --prefix=/hpc/base/swstack \
    --with-hcoll=/opt/mellanox/hpc-x/hpc-x-v2.21/hcoll
```

## All options

| Option | Default | Description |
|---|---|---|
| `--compiler=` | — | `gcc` \| `aocc` \| `intel` (required) |
| `--compiler-version=` | — | e.g. `2025.2.1` (required) |
| `--ompi-version=` | — | e.g. `5.0.9` (required) |
| `--ucx-version=` | — | e.g. `1.20.0`, or `system` to use system UCX (required) |
| `--ucx=system` | — | Alias for `--ucx-version=system` |
| `--ucc-version=` | — | e.g. `1.3.0` (required) |
| `--prefix=` | — | Installation root (required) |
| `--module-root=` | `$PWD/modules` | Where to write Lmod `.lua` files |
| `--with-hcoll[=PATH]` | disabled | Enable hcoll; auto-detect or explicit path |
| `--without-hcoll` | ✓ default | Disable hcoll |
| `--with-cuda[=PATH]` | auto-detect | Enable GPU-aware MPI |
| `--without-cuda` | — | Force-disable CUDA |
| `--with-gdrcopy[=PATH]` | auto-detect | Enable GDRCopy (intra-node GPU DMA) |
| `--skip-ucx` | — | Skip UCX build, use existing install |
| `--skip-ucc` | — | Skip UCC build, use existing install |
| `--skip-ompi` | — | Skip OpenMPI build |
| `--dry-run` | — | Print config and exit, no build |

## Install paths

Everything installs under:
```
$PREFIX/<pkg>/<version>/<compiler>/<compiler_version>/
```
e.g.:
```
/hpc/base/swstack/ucx/1.20.0/intel/2025.2.1/
/hpc/base/swstack/ucc/1.3.0/intel/2025.2.1/
/hpc/base/swstack/openmpi/5.0.9/intel/2025.2.1/
```

## Lmod modules

Generated at `--module-root` (default `$PWD/modules`):
```
modules/ucx/1.20.0/intel/2025.2.1.lua
modules/ucc/1.3.0/intel/2025.2.1.lua
modules/openmpi/5.0.9/intel/2025.2.1.lua
```

Load with:
```bash
module use /path/to/modules
module load openmpi/5.0.9/intel/2025.2.1
```
The OpenMPI module automatically prepends paths for UCX, UCC (and hcoll if used).
When `--ucx-version=system` is used, no UCX module is generated and the OpenMPI
module does not prepend UCX paths.

## Environment overrides

| Variable | Effect |
|---|---|
| `CUDA_HOME` / `CUDA_ROOT` | Override CUDA auto-detection |
| `HCOLL_DIR` | Override hcoll auto-detection |
| `NCCL_HOME` | Override NCCL path for UCC |
| `UCXCUDAOPT` | Extra space-separated UCX CUDA configure args |

## hcoll vs UCC

hcoll is a closed-source Mellanox/NVIDIA collective offload library removed in
OpenMPI 6. UCC (open source, same team) is the replacement and supports SHARP
hardware acceleration through UCX. Use `--with-hcoll` only for clusters that
cannot yet use UCC, and only point it at the HPC-X bundled hcoll — the
standalone `/opt/mellanox/hcoll` is known to cause ABI segfaults with
OpenMPI 5.x.

## Verifying the build

```bash
# Check UCC and UCX are wired in
ompi_info | grep -E "ucc|ucx|cuda|hcoll"

# Check GPU-aware MPI
ompi_info | grep -i cuda

# UCX transports
ucx_info -d

# Quick ping-pong sanity check
mpicc -O2 -o pingpong pingpong.c
mpirun -np 2 --map-by node ./pingpong
```
