#!/bin/bash
# lib/patches.sh - conditional source patch application

_patch_dir_exists() {
    local dir="$1"
    [[ -d "$dir" ]]
}

_apply_patch_file() {
    local patch_file="$1"
    local source_dir="$2"
    local strip="${PATCH_STRIP:-1}"

    log_info "Applying patch: ${patch_file}"
    (
        cd "$source_dir"
        patch --forward -p"$strip" < "$patch_file"
    ) || log_die "Patch failed: ${patch_file}"
}

# apply_package_patches <pkg> <version> <compiler> <compiler_version> <source_dir>
#
# Patches are selected by directory. More specific directories are applied
# after broader ones, so package-wide patches can be refined by version and
# compiler-specific patches.
#
# Supported locations:
#   patches/<pkg>/all/*.patch
#   patches/<pkg>/<version>/*.patch
#   patches/<pkg>/<compiler>/*.patch
#   patches/<pkg>/<compiler>/<compiler_version>/*.patch
#   patches/<pkg>/<version>/<compiler>/*.patch
#   patches/<pkg>/<version>/<compiler>/<compiler_version>/*.patch
apply_package_patches() {
    local pkg="$1"
    local version="$2"
    local compiler="$3"
    local compiler_version="$4"
    local source_dir="$5"
    local patch_root="${PATCH_ROOT:-${SCRIPT_DIR}/patches}"
    local pkg_root="${patch_root}/${pkg}"
    local dir patch_file
    local applied=0
    local -a candidate_dirs

    case "$patch_root" in
        /*) ;;
        *) patch_root="${START_DIR:-$PWD}/${patch_root}" ;;
    esac
    pkg_root="${patch_root}/${pkg}"

    [[ -d "$pkg_root" ]] || return 0
    [[ -d "$source_dir" ]] || log_die "Patch source directory not found: ${source_dir}"

    candidate_dirs=(
        "${pkg_root}/all"
        "${pkg_root}/${version}"
        "${pkg_root}/${compiler}"
        "${pkg_root}/${compiler}/${compiler_version}"
        "${pkg_root}/${version}/${compiler}"
        "${pkg_root}/${version}/${compiler}/${compiler_version}"
    )

    shopt -s nullglob
    for dir in "${candidate_dirs[@]}"; do
        _patch_dir_exists "$dir" || continue
        for patch_file in "$dir"/*.patch; do
            _apply_patch_file "$patch_file" "$source_dir"
            applied=1
        done
    done
    shopt -u nullglob

    if [[ $applied -eq 0 ]]; then
        log_info "No matching ${pkg} patches for ${version}/${compiler}/${compiler_version}"
    fi
}
