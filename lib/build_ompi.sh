#!/bin/bash
# lib/build_ompi.sh — OpenMPI download, configure, build, install

ompi_download() {
    local version="$1"
    local tarball="openmpi-${version}.tar.gz"
    local url=""

    case "$version" in
    6.*)  url="https://download.open-mpi.org/release/open-mpi/v6.0/${tarball}" ;;
    5.*)  url="https://download.open-mpi.org/release/open-mpi/v5.0/${tarball}" ;;
    4.*)  url="https://download.open-mpi.org/release/open-mpi/v4.0/${tarball}" ;;
    *)    log_die "Unsupported OpenMPI version: $version" ;;
    esac

    log_info "Preparing OpenMPI ${version}..."

    if [[ -f "$tarball" ]]; then
        log_info "Tarball exists: $tarball (skipping download)"
    else
        log_info "Downloading: $url"
        wget -q --show-progress -c "$url" || log_die "OpenMPI download failed"
    fi

    if [[ -d "openmpi-${version}" ]]; then
        log_info "Removing stale source dir openmpi-${version}"
        rm -rf "openmpi-${version}"
    fi

    tar -xzf "$tarball" || log_die "OpenMPI extraction failed"
}

# ompi_build <version> <install_prefix> <ucx_prefix> <ucc_prefix>
#            <hcoll_mode> <hcoll_dir|""> <cuda_dir|"">
ompi_build() {
    local version=$1
    local install_dir=$2
    local ucx_dir=$3
    local ucc_dir=$4
    local hcoll_mode=$5
    local hcoll_dir="${6:-}"
    local cuda_dir="${7:-}"
    local build_dir="openmpi-${version}"
    local compiler_basename="${CC##*/}"
    local knem_dir=""
    local prte_flag=""
    local ucx_arg=""
    local ucc_arg="--without-ucc"
    local -a configure_args

    log_info "Configuring OpenMPI ${version} → ${install_dir}"
    cd "$build_dir"

    # Accumulate CPPFLAGS / LDFLAGS / LD_LIBRARY_PATH additions
    local extra_cpp="" extra_ld="" extra_rpath=""

    # --- UCX ---
    if [[ "$ucx_dir" == "system" ]]; then
        log_info "OpenMPI: enabling system UCX"
        ucx_arg="--with-ucx"
    else
        extra_cpp+=" -I${ucx_dir}/include"
        extra_ld+=" -L${ucx_dir}/lib"
        extra_rpath+=" -Wl,-rpath,${ucx_dir}/lib"
        export LD_LIBRARY_PATH="${ucx_dir}/lib:${LD_LIBRARY_PATH:-}"
        ucx_arg="--with-ucx=${ucx_dir}"
    fi

    # --- UCC ---
    if [[ -n "$ucc_dir" ]]; then
        log_info "OpenMPI: enabling UCC ($ucc_dir)"
        extra_cpp+=" -I${ucc_dir}/include"
        extra_ld+=" -L${ucc_dir}/lib"
        extra_rpath+=" -Wl,-rpath,${ucc_dir}/lib"
        export LD_LIBRARY_PATH="${ucc_dir}/lib:${LD_LIBRARY_PATH:-}"
        ucc_arg="--with-ucc=${ucc_dir}"
    else
        log_info "OpenMPI: UCC disabled"
    fi

    # --- hcoll ---
    local hcoll_arg="--without-hcoll"
    case "$hcoll_mode" in
    no)
        log_info "OpenMPI: hcoll disabled"
        hcoll_arg="--without-hcoll"
        ;;
    yes:*|auto)
        if [[ -n "$hcoll_dir" ]]; then
            log_info "OpenMPI: enabling hcoll ($hcoll_dir)"
            extra_cpp+=" -I${hcoll_dir}/include"
            extra_ld+=" -L${hcoll_dir}/lib"
            extra_rpath+=" -Wl,-rpath,${hcoll_dir}/lib"
            export LD_LIBRARY_PATH="${hcoll_dir}/lib:${LD_LIBRARY_PATH:-}"
            hcoll_arg="--with-hcoll=${hcoll_dir}"
        else
            log_info "OpenMPI: hcoll not resolved — disabling"
            hcoll_arg="--without-hcoll"
        fi
        ;;
    esac

    # --- CUDA ---
    local cuda_arg="--without-cuda"
    if [[ -n "$cuda_dir" ]]; then
        log_info "OpenMPI: enabling CUDA ($cuda_dir)"
        extra_cpp+=" -I${cuda_dir}/include"
        extra_ld+=" -L${cuda_dir}/lib64"
        extra_rpath+=" -Wl,-rpath,${cuda_dir}/lib64"
        cuda_arg="--with-cuda=${cuda_dir}"
    fi

    # prte prefix flag differs between 4.x and 5.x/6.x
    case "$version" in
    4.*) prte_flag="--enable-mpirun-prefix-by-default" ;;
    *)   prte_flag="--enable-prte-prefix-by-default" ;;
    esac

    configure_args=(
        "--prefix=${install_dir}"
        "${prte_flag}"
        "--enable-mpi1-compatibility"
        "--enable-mpi-fortran=all"
        "$ucx_arg"
        "$ucc_arg"
        "--with-pmix"
        "--with-ofi=no"
        "$hcoll_arg"
        "$cuda_arg"
    )
    if [[ "$ucx_dir" != "system" ]]; then
        configure_args+=("--with-ucx-libdir=${ucx_dir}/lib")
    fi

    if knem_dir=$(find_knem_dir 2>/dev/null); then
        log_info "OpenMPI: enabling knem ($knem_dir)"
        configure_args+=("--with-knem=${knem_dir}")
    fi

    export CPPFLAGS="${extra_cpp# } ${CPPFLAGS:-}"
    export LDFLAGS="${extra_ld# } ${extra_rpath# } ${LDFLAGS:-}"

    log_info "Building OpenMPI ($(nproc) jobs)..."

    if [[ "$compiler_basename" == "clang" ]]; then
        # AOCC: half-precision float shim + suppress unused-arg warnings
        local COMMONFLAGS="-O3 -fPIC -m64 -Wno-error"
        CC=${CC} CXX=${CXX} FC=${FC} \
            CFLAGS="$COMMONFLAGS" CXXFLAGS="$COMMONFLAGS" FCFLAGS="$COMMONFLAGS" \
            LDFLAGS="${LDFLAGS} $COMMONFLAGS --rtlib=compiler-rt -lunwind" \
            ./configure --with-wrapper-ldflags=--rtlib=compiler-rt \
            "${configure_args[@]}"
    else
        CC=${CC} CXX=${CXX} FC=${FC} \
            CFLAGS="-O3" CXXFLAGS="-O3" FCFLAGS="-O3" \
            ./configure "${configure_args[@]}"
    fi

    make -j"$(nproc)"
    make install

    cd ..
    log_ok "OpenMPI ${version} installed → ${install_dir}"
}
