#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=${0##*/}
case "$0" in
    */*) SCRIPT_DIR=$(cd "${0%/*}" && pwd) ;;
    *)   SCRIPT_DIR=$PWD ;;
esac

CLEAN=${CLEAN:-0}
SKIP_FETCH=${SKIP_FETCH:-0}
SKIP_BUILD=${SKIP_BUILD:-0}
CCACHE_OPT=${CCACHE_OPT:-}
WORK_DIR=${WORK_DIR:-"$SCRIPT_DIR/work"}
KERNEL_DIR=${KERNEL_DIR:-common}
KERNEL_REPO=${KERNEL_REPO:-https://github.com/CloudFox-INC/CloudFox-Kernel}
KERNEL_BRANCH=${KERNEL_BRANCH:-}
KERNEL_COMMIT=${KERNEL_COMMIT:-}
PREBUILTS_REPO=${PREBUILTS_REPO:-}
PREBUILTS_TAG=${PREBUILTS_TAG:-prebuilts}
ACK_PREBUILTS_BRANCH=${ACK_PREBUILTS_BRANCH:-master}
CLANG_ASSET=${CLANG_ASSET:-clang-r536225-linux-x86.tar.zst}
CLANG_UPSTREAM_REPO=${CLANG_UPSTREAM_REPO:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86}
KBUILD_TOOLS_ASSET=${KBUILD_TOOLS_ASSET:-kernel-build-tools.tar.zst}
KBUILD_TOOLS_UPSTREAM_REPO=${KBUILD_TOOLS_UPSTREAM_REPO:-https://android.googlesource.com/kernel/prebuilts/build-tools}
BUILDTOOLS_ASSET=${BUILDTOOLS_ASSET:-build-tools.tar.zst}
BUILDTOOLS_UPSTREAM_REPO=${BUILDTOOLS_UPSTREAM_REPO:-https://android.googlesource.com/platform/prebuilts/build-tools}
GCC_HOST_UPSTREAM_REPO=${GCC_HOST_UPSTREAM_REPO:-https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8}
CLANG_URL=${CLANG_URL:-}
KBUILD_TOOLS_URL=${KBUILD_TOOLS_URL:-}
BUILDTOOLS_URL=${BUILDTOOLS_URL:-}
GAS_URL=${GAS_URL:-}
JOBS=${JOBS:-}
BUILD_CONFIG=${BUILD_CONFIG:-}
DEFCONFIG_FRAGMENT=${DEFCONFIG_FRAGMENT:-}
DEFCONFIG_FRAGMENT_EXCLUDE=${DEFCONFIG_FRAGMENT_EXCLUDE:-}
APPEND_BUILD_ENV=${APPEND_BUILD_ENV:-}
APPEND_CONFIG=${APPEND_CONFIG:-}
LTO=${LTO:-thin} # Default LTO set to full

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
rel() { case "$1" in "$SCRIPT_DIR/"*) printf '%s\n' ".${1#"$SCRIPT_DIR"}" ;; *) printf '%s\n' "$1" ;; esac; }

config_get() { 
    local key=$2
    grep -m1 -E "^(export[[:space:]]+)?$key=" "$1" 2>/dev/null | cut -d= -f2- | xargs || true
}
curl_dl() { curl --connect-timeout 10 "$@"; }

usage() {
    cat <<EOF
Usage: ./$SCRIPT_NAME [options]
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-repo)   KERNEL_REPO=$2; shift 2 ;;
        --kernel-branch) KERNEL_BRANCH=$2; shift 2 ;;
        --kernel-commit) KERNEL_COMMIT=$2; shift 2 ;;
        --clang-url)     CLANG_URL=$2; shift 2 ;;
        --work-dir)      WORK_DIR=$2; shift 2 ;;
        --jobs|-j)       JOBS=$2; shift 2 ;;
        --defconfig-fragment) DEFCONFIG_FRAGMENT=$2; shift 2 ;;
        --defconfig-fragment-exclude) DEFCONFIG_FRAGMENT_EXCLUDE=${DEFCONFIG_FRAGMENT_EXCLUDE:+$DEFCONFIG_FRAGMENT_EXCLUDE }$2; shift 2 ;;
        --clean)         CLEAN=1; shift ;;
        --ccache)        CCACHE_OPT=1; shift ;;
        --skip-fetch)    SKIP_FETCH=1; shift ;;
        --skip-build)    SKIP_BUILD=1; shift ;;
        -h|--help)       usage 0 ;;
        *)               err "unknown option: $1"; usage 1 ;;
    esac
done

if [ -z "$PREBUILTS_REPO" ]; then
    PREBUILTS_REPO=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)
fi
case "$PREBUILTS_REPO" in
    git@github.com:*)   PREBUILTS_REPO=https://github.com/${PREBUILTS_REPO#git@github.com:} ;;
    git://github.com/*) PREBUILTS_REPO=https://github.com/${PREBUILTS_REPO#git://github.com/} ;;
esac
PREBUILTS_REPO=${PREBUILTS_REPO%.git}
PREBUILTS_REPO=${PREBUILTS_REPO:-https://github.com/CloudFox-INC/CloudFox-Kernel-Builder}
RELEASE_BASE=$PREBUILTS_REPO/releases/download/$PREBUILTS_TAG
REPO_PATH=${PREBUILTS_REPO#https://github.com/}
REPO_PATH=${REPO_PATH#http://github.com/}
REPO_PATH=${REPO_PATH%.git}
API_BASE=https://api.github.com/repos/$REPO_PATH

download_asset() {
    local asset=$1 out=$2 fallback=${3:-} api_url
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        curl_dl -fL --retry 3 -sS -o "$out" "$RELEASE_BASE/$asset" && return 0
        [ -n "$fallback" ] && curl_dl -fL --retry 3 -sS -o "$out" "$fallback" && return 0
        return 1
    fi
    if curl_dl -fL --retry 3 -sS -o "$out" "$RELEASE_BASE/$asset" 2>/dev/null; then
        return 0
    fi
    api_url=$(curl_dl -sfL -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
        "$API_BASE/releases/tags/$PREBUILTS_TAG" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    a=[x for x in d.get('assets',[]) if x['name']==sys.argv[1]]
    print(a[0]['url'] if a else '')
except Exception:
    pass
" "$asset" 2>/dev/null || true)
    if [ -n "$api_url" ] && curl_dl -fL --retry 3 -sS \
        -H "Authorization: Bearer ${GITHUB_TOKEN:-}" -H "Accept: application/octet-stream" \
        -o "$out" "$api_url"; then
        return 0
    fi
    [ -n "$fallback" ] && curl_dl -fL --retry 3 -sS -o "$out" "$fallback" && return 0
    return 1
}

preflight() {
    local missing=0 t
    for t in git curl zstd tar which bash sh perl rsync find grep realpath; do
        command -v "$t" >/dev/null 2>&1 || { warn "missing host tool: $t"; missing=1; }
    done
    [ "$missing" -eq 0 ] || die "install the missing tools and re-run"
    case "$KERNEL_REPO" in
        *://*)       : ;;
        *@*:*)       : ;;
        *) die "KERNEL_REPO must be a full URL or scp-style remote (got: '$KERNEL_REPO')" ;;
    esac
}

fetch_build_scripts() {
    if [ -x "$WORK_DIR/build/build.sh" ]; then
        ok "build scripts present at $(rel "$WORK_DIR/build")"
        return
    fi
    rm -rf "${WORK_DIR:?}/build"
    mkdir -p "$WORK_DIR"
    if [ -x "$SCRIPT_DIR/build/build.sh" ]; then
        cp -a "$SCRIPT_DIR/build" "$WORK_DIR/build"
    else
        die "in-repo build scripts missing at $SCRIPT_DIR/build"
    fi
    ok "build scripts copied from repo"
}

fetch_kernel() {
    if [ -d "$WORK_DIR/$KERNEL_DIR/.git" ]; then
        ok "kernel source present at $(rel "$WORK_DIR/$KERNEL_DIR")"
        return
    fi
    rm -rf "${WORK_DIR:?}/${KERNEL_DIR:?}"
    if [ -n "$KERNEL_COMMIT" ]; then
        git init -q "$WORK_DIR/$KERNEL_DIR"
        git -C "$WORK_DIR/$KERNEL_DIR" remote add origin "$KERNEL_REPO"
        git -C "$WORK_DIR/$KERNEL_DIR" fetch -q --depth 1 origin "$KERNEL_COMMIT"
        git -C "$WORK_DIR/$KERNEL_DIR" checkout -q FETCH_HEAD
    else
        local args=(clone -q --depth 1)
        [ -z "$KERNEL_BRANCH" ] || args+=(-b "$KERNEL_BRANCH")
        git "${args[@]}" "$KERNEL_REPO" "$WORK_DIR/$KERNEL_DIR"
    fi
    ok "kernel source cloned"
}

resolve_clang_dir() {
    local dir found
    # Add Neutron Clang directory to search path
    for dir in "$WORK_DIR/neutron-clang" \
               "$WORK_DIR/prebuilts-master/clang/host/linux-x86" \
               "$WORK_DIR/prebuilts/clang/host/linux-x86" \
               "$WORK_DIR"; do
        found=$(find "$dir" \
            \( -path "$WORK_DIR/$KERNEL_DIR" -o -path "$WORK_DIR/out" \
               -o -path "$WORK_DIR/downloads" -o -path "$WORK_DIR/build" \
               -o -path "$WORK_DIR/dist" \) -prune -o \
            -maxdepth 8 -path '*/bin/clang' -executable -print -quit 2>/dev/null || true)
        [ -n "$found" ] || continue
        printf '%s\n' "${found%/bin/clang}"
        return 0
    done
    return 1
}

fetch_clang_download() {
    if [[ "${CLANG_ASSET:-}" == *"neutron"* ]]; then return 0; fi
    local tarball=$WORK_DIR/downloads/clang.tar.zst
    local clang_dir
    clang_dir=$(resolve_clang_dir || true)
    [ -n "$clang_dir" ] && [ -x "$clang_dir/bin/clang" ] && return 0
    [ -s "$tarball" ] && return 0
    mkdir -p "$WORK_DIR/downloads"
    if [ -n "$CLANG_URL" ]; then
        curl_dl -fL --retry 3 -sS -o "$tarball.part" "$CLANG_URL" || { rm -f "$tarball.part"; return 1; }
    else
        download_asset "$CLANG_ASSET" "$tarball.part" || { rm -f "$tarball.part"; return 1; }
    fi
    mv -f "$tarball.part" "$tarball"
    ok "clang tarball downloaded"
}

fetch_clang_extract() {
    if [[ "${CLANG_ASSET:-}" == *"neutron"* ]]; then return 0; fi
    local root=$WORK_DIR/prebuilts-master/clang/host/linux-x86
    local tarball=$WORK_DIR/downloads/clang.tar.zst
    local clang_dir
    clang_dir=$(resolve_clang_dir || true)
    [ -n "$clang_dir" ] && [ -x "$clang_dir/bin/clang" ] && return 0
    [ -s "$tarball" ] || return 0
    mkdir -p "$root"
    tar -I 'zstd -T0' -xf "$tarball" -C "$root"
    clang_dir=$(resolve_clang_dir || true)
    [ -n "$clang_dir" ] && [ -x "$clang_dir/bin/clang" ] || return 1
    ok "clang toolchain ready at $(rel "$clang_dir")"
}

fetch_clang() {
    # Custom Logic for Neutron Clang 24 Download
    if [[ "${CLANG_ASSET:-}" == *"neutron"* ]]; then
        local neutron_dir="$WORK_DIR/neutron-clang"
        if [ ! -x "$neutron_dir/bin/clang" ]; then
            info "Downloading Neutron Clang via antman..."
            mkdir -p "$neutron_dir"
            
            # Yahan par antman ko correctly download aur execute permission di gayi hai
            (cd "$neutron_dir" && curl -sO "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman" && chmod +x antman && ./antman -S && ./antman --patch=glibc)
        fi
        
        local clang_dir
        clang_dir=$(resolve_clang_dir || true)
        [ -n "$clang_dir" ] && [ -x "$clang_dir/bin/clang" ] || die "no usable neutron clang toolchain"
        ok "Neutron clang toolchain ready at $(rel "$clang_dir")"

        local pin pin_dir
        pin=$(config_get "$WORK_DIR/$KERNEL_DIR/build.config.common" CLANG_PREBUILT_BIN || true)
        case "$pin" in
            */bin) pin_dir=${pin%/bin} ;;
            *)     pin_dir=$pin ;;
        esac
        if [ -n "$pin" ] && [ -n "$clang_dir" ]; then
            mkdir -p "$(dirname "$WORK_DIR/$pin_dir")" 2>/dev/null || true
            ln -sfnT "$clang_dir" "$WORK_DIR/$pin_dir"
        fi
        return 0
    fi

    # ... Yahan se aage ka purana code waise hi rehne dein ...


    local root=$WORK_DIR/prebuilts-master/clang/host/linux-x86
    local tarball=$WORK_DIR/downloads/clang.tar.zst
    local pin pin_dir pin_name clang_dir
    pin=$(config_get "$WORK_DIR/$KERNEL_DIR/build.config.common" CLANG_PREBUILT_BIN)
    case "$pin" in
        */bin) pin_dir=${pin%/bin} ;;
        *)     pin_dir=$pin ;;
    esac
    pin_name=${pin_dir##*/}
    [ -z "$pin_name" ] && pin_name=clang-r416183b
    mkdir -p "$root"
    clang_dir=$(resolve_clang_dir || true)
    if [ -n "$clang_dir" ] && [ -x "$clang_dir/bin/clang" ]; then
        ok "clang toolchain present at $(rel "$clang_dir")"
    else
        if [ -s "$tarball" ]; then
            tar -I 'zstd -T0' -xf "$tarball" -C "$root"
        elif [ -n "$CLANG_URL" ]; then
            curl_dl -fL --retry 3 -o "$tarball" "$CLANG_URL" || die "failed to download clang from $CLANG_URL"
            tar -I 'zstd -T0' -xf "$tarball" -C "$root"
        elif ! download_asset "$CLANG_ASSET" "$tarball"; then
            warn "no prebuilt clang bundle, sparse-cloning $CLANG_UPSTREAM_REPO"
            rm -rf "$root"
            git clone -q --depth 1 --filter=blob:none --sparse \
                -b "$ACK_PREBUILTS_BRANCH" "$CLANG_UPSTREAM_REPO" "$root" \
                || { rm -rf "$root"; git clone -q --depth 1 -b "$ACK_PREBUILTS_BRANCH" "$CLANG_UPSTREAM_REPO" "$root"; }
            git -C "$root" sparse-checkout set "$pin_name"
        else
            tar -I 'zstd -T0' -xf "$tarball" -C "$root"
        fi
        clang_dir=$(resolve_clang_dir || true)
        [ -n "$clang_dir" ] && [ -x "$clang_dir/bin/clang" ] || die "no usable clang toolchain anywhere"
        ok "clang toolchain ready at $(rel "$clang_dir")"
    fi
    if [ -n "$pin" ] && [ -x "$WORK_DIR/$pin_dir/bin/clang" ]; then
        ok "clang path pinned by build.config.common resolves"
    elif [ -n "$pin" ] && [ -n "$clang_dir" ]; then
        ln -sfnT "$clang_dir" "$WORK_DIR/$pin_dir"
        ok "linked clang toolchain to the pinned path"
    fi
}

fetch_ccache() {
    command -v ccache >/dev/null 2>&1 && return 0
    local arch
    arch=$(uname -m)
    [ "$arch" = "x86_64" ] || { warn "ccache: unsupported arch '$arch'; skipping"; return 0; }
    local ver=4.13.6
    local tmp="$WORK_DIR/downloads/ccache.tar.xz"
    mkdir -p "$WORK_DIR/downloads"
    curl_dl -fL --retry 3 -sS -o "$tmp" \
        "https://github.com/ccache/ccache/releases/download/v${ver}/ccache-${ver}-linux-x86_64-glibc.tar.xz" \
        || { warn "ccache: download failed; building without ccache"; return 0; }
    local tree
    tree=$(mktemp -d)
    tar -xJf "$tmp" -C "$tree" --strip-components=1 \
        && sudo install -m 0755 "$tree/ccache" /usr/local/bin/ccache
    rm -rf "$tree"
    command -v ccache >/dev/null 2>&1 || warn "ccache: install incomplete"
}

install_ccache_wrappers() {
    [ -n "${CCACHE_OPT:-}" ] || return 0
    [ -n "${CCACHE_WRAPPED:-}" ] && return 0   
    local ccache_bin
    ccache_bin=$(command -v ccache) || { warn "ccache requested but not installed"; CCACHE_OPT=; return 0; }
    local clang_dir
    clang_dir=$(resolve_clang_dir || true)
    if [ -z "$clang_dir" ] || [ ! -x "$clang_dir/bin/clang" ]; then
        warn "ccache: no clang toolchain to wrap"; CCACHE_OPT=; return 0
    fi
    "$ccache_bin" -o cache_dir="$WORK_DIR/.ccache" >/dev/null 2>&1 || true
    mkdir -p "$WORK_DIR/.ccache" "$clang_dir/.cfx-orig-bin"
    local tool target orig realbin
    for tool in clang clang++ ${CCACHE_LINK_TOOLS:-aarch64-linux-gnu-clang aarch64-linux-gnu-clang++}; do
        target="$clang_dir/bin/$tool"
        [ -x "$target.real" ] && target="$target.real"
        [ -e "$target" ] || [ -L "$target" ] || continue
        realbin=
        [ -L "$target" ] && realbin=$(readlink -f -- "$target" 2>/dev/null)
        orig="$clang_dir/.cfx-orig-bin/$(basename -- "$target")"
        if [ ! -e "$orig" ] && [ ! -L "$orig" ]; then
            mv -- "$target" "$orig"
        fi
        [ -n "$realbin" ] || realbin="$orig"
        [ -x "$realbin" ] || continue
        rm -f -- "$target"
        cat > "$target" <<EOF
#!/usr/bin/env bash
exec "$ccache_bin" "$realbin" "\$@"
EOF
        chmod +x "$target"
    done
    export CCACHE_COMPILERCHECK=content
    export CCACHE_NOHASHDIR=true
    export CCACHE_BASEDIR="$WORK_DIR"
    export CCACHE_SLOPPINESS=file_macro,time_macros,include_file_mtime,include_file_ctime,pch_defines,system_headers,locale
    export CCACHE_IGNOREOPTIONS=--sysroot*
    export CCACHE_DIRECT=true
    export CCACHE_COMPRESSION=true
    export CCACHE_COMPRESSION_LEVEL=1
    export CCACHE_MAXSIZE=12G
    export CCACHE_DIR="$WORK_DIR/.ccache"
    if "$ccache_bin" --help 2>&1 | grep -qi 'depend'; then
        export CCACHE_DEPEND=true
    fi
    CCACHE_WRAPPED=1
    info "ccache wrappers installed on $(rel "$clang_dir") toolchain"
}

restore_ccache_wrappers() {
    [ -n "${CCACHE_OPT:-}" ] || return 0
    local clang_dir=$(resolve_clang_dir || true)
    [ -z "$clang_dir" ] || [ ! -d "$clang_dir/.cfx-orig-bin" ] && return 0
    local f
    for f in "$clang_dir/.cfx-orig-bin/"*; do
        [ -e "$f" ] || continue
        mv -f -- "$f" "$clang_dir/bin/$(basename -- "$f")"
    done
    rm -rf "$clang_dir/.cfx-orig-bin"
}

fetch_prebuilt_tree() { 
    local dest=$1 tarball=$2 url=$3 asset=$4 upstream=$5; shift 5
    local -a sparse=("$@")
    rm -rf "$dest"
    mkdir -p "$dest"
    if [ -z "$url" ]; then
        if download_asset "$asset" "$tarball"; then
            tar -I 'zstd -T0' -xf "$tarball" -C "$dest"
        else
            warn "no prebuilt bundle, cloning $upstream"
            if [ "${#sparse[@]}" -gt 0 ]; then
                git clone -q --depth 1 --filter=blob:none --sparse \
                    -b "$ACK_PREBUILTS_BRANCH" "$upstream" "$dest" \
                    && git -C "$dest" sparse-checkout set "${sparse[@]}" \
                    || { rm -rf "$dest"; git clone -q --depth 1 -b "$ACK_PREBUILTS_BRANCH" "$upstream" "$dest"; }
            else
                git clone -q --depth 1 -b "$ACK_PREBUILTS_BRANCH" "$upstream" "$dest"
            fi
        fi
    else
        curl_dl -fL --retry 3 -o "$tarball" "$url"
        tar -I 'zstd -T0' -xf "$tarball" -C "$dest"
    fi
}

fetch_kernel_build_tools() {
    local kbt=$WORK_DIR/prebuilts/kernel-build-tools
    local tarball=$WORK_DIR/downloads/kernel-build-tools.tar.zst
    if [ -x "$kbt/linux-x86/bin/dtc" ]; then
        ok "kernel-build-tools present"
        return
    fi
    fetch_prebuilt_tree "$kbt" "$tarball" "$KBUILD_TOOLS_URL" "$KBUILD_TOOLS_ASSET" "$KBUILD_TOOLS_UPSTREAM_REPO" linux-x86
    [ -x "$kbt/linux-x86/bin/dtc" ] || die "kernel-build-tools missing linux-x86/bin/dtc"
    ok "kernel-build-tools ready"
}

fetch_build_tools() {
    local bt=$WORK_DIR/prebuilts/build-tools
    local tarball=$WORK_DIR/downloads/build-tools.tar.zst
    if [ -x "$bt/linux-x86/bin/make" ] && [ -x "$bt/path/linux-x86/python3" ]; then
        ok "build-tools present"
        return
    fi
    fetch_prebuilt_tree "$bt" "$tarball" "$BUILDTOOLS_URL" "$BUILDTOOLS_ASSET" "$BUILDTOOLS_UPSTREAM_REPO" linux-x86 path/linux-x86 common/bison
    [ -x "$bt/linux-x86/bin/make" ] || die "build-tools missing linux-x86/bin/make"
    [ -x "$bt/path/linux-x86/python3" ] || die "build-tools missing path/linux-x86/python3"
    ok "build-tools ready"
}

fetch_gcc_host() {
    local gcc_root=$WORK_DIR/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8
    if [ -d "$gcc_root/sysroot" ]; then
        ok "gcc host sysroot present"
        return
    fi
    rm -rf "${gcc_root:?}"
    mkdir -p "$gcc_root"
    if [ -d "$SCRIPT_DIR/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/sysroot" ]; then
        cp -a "$SCRIPT_DIR/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/sysroot" "$gcc_root/"
    else
        warn "sysroot not in repo, sparse-cloning $GCC_HOST_UPSTREAM_REPO"
        git clone -q --depth 1 --filter=blob:none --sparse "$GCC_HOST_UPSTREAM_REPO" "$gcc_root" 2>/dev/null \
            || git clone -q --depth 1 "$GCC_HOST_UPSTREAM_REPO" "$gcc_root"
        git -C "$gcc_root" sparse-checkout set sysroot
    fi
    [ -d "$gcc_root/sysroot" ] || die "gcc host sysroot missing"
    ok "gcc host sysroot ready"
}

fetch_gas() {
    [ -z "$GAS_URL" ] && return
    local gas=$WORK_DIR/prebuilts/gas/linux-x86
    [ -d "$gas/.git" ] && return
    git clone -q --depth 1 "$GAS_URL" "$gas"
    ok "gas prebuilt ready"
}

verify_build_tools_links() {
    local farm=$WORK_DIR/build/build-tools/path/linux-x86
    if [ ! -d "$farm" ]; then
        warn "no symlink farm at $farm"
        return
    fi
    local broken=0 n=0 f
    for f in "$farm"/*; do
        n=$((n + 1))
        if [ -L "$f" ]; then
            [ -e "$f" ] || { warn "unresolved build tool link: $(basename "$f")"; broken=1; }
        elif [ ! -e "$f" ]; then
            warn "not a symlink and not a file: $f"
            broken=1
        fi
    done
    if [ "$broken" -eq 0 ]; then
        ok "build-tools symlink farm resolves ($n tools)"
    else
        warn "some hermetic build tools are unresolved"
    fi
}

write_build_config() {
    cat > "$WORK_DIR/build.config.cloudfox" <<EOF
export KERNEL_DIR=$KERNEL_DIR
. \${ROOT_DIR}/\${KERNEL_DIR}/build.config.gki.aarch64
export POST_DEFCONFIG_CMDS="\${ROOT_DIR}/build/self-heal-config.sh"
EOF
    if [ -n "$CLANG_URL" ] || [[ "${CLANG_ASSET:-}" == *"neutron"* ]]; then
        cat >> "$WORK_DIR/build.config.cloudfox" <<'EOF'
export HERMETIC_TOOLCHAIN=0
export CLOUDFOX_HOST_CC=${CLOUDFOX_HOST_CC:-gcc}
export CLOUDFOX_HOST_CXX=${CLOUDFOX_HOST_CXX:-g++}
EOF
        ok "custom-toolchain host-tool override appended"
    fi
    if [ -n "$APPEND_BUILD_ENV" ]; then
        local IFS=, pair
        {
            printf '\n# CloudFox addition: caller-appended build env\n'
            for pair in $APPEND_BUILD_ENV; do
                [ -n "$pair" ] && printf 'export %s\n' "$pair"
            done
        } >> "$WORK_DIR/build.config.cloudfox"
        ok "caller build env appended"
    fi
}

resolve_fragment_dir() {
    local branch=$KERNEL_BRANCH suffix frag_dir
    if [ -z "$branch" ]; then
        branch=$(git -C "$WORK_DIR/$KERNEL_DIR" branch --show-current 2>/dev/null || true)
        [ -n "$branch" ] && info "KERNEL_BRANCH empty; resolved from clone: $branch" >&2
    fi
    if [ -n "$branch" ] && [ "${branch#android12-5.10-}" != "$branch" ]; then
        suffix=${branch#android12-5.10-}
        frag_dir=$SCRIPT_DIR/build/fragments/$suffix
        if [ -d "$frag_dir" ]; then
            printf '%s\n' "$frag_dir"
            return 0
        fi
    fi
    if [ -d "$SCRIPT_DIR/build/fragments/default" ]; then
        printf '%s\n' "$SCRIPT_DIR/build/fragments/default"
    fi
}

apply_defconfig_fragment() {
    local frags=${DEFCONFIG_FRAGMENT:-}
    [ -n "$frags" ] || frags=$(resolve_fragment_dir)
    if [ -d "$frags" ]; then
        frags=$(shopt -s nullglob; printf '%s\n' "$frags"/*.config | sort -d)
    fi
    if [ -n "$DEFCONFIG_FRAGMENT_EXCLUDE" ]; then
        local excl=${DEFCONFIG_FRAGMENT_EXCLUDE//,/ }
        local -a keep=()
        local frag name core drop e
        for frag in $frags; do
            [ -z "$frag" ] && continue
            name=$(basename "$frag")
            core=${name%.config}
            core=${core%-*}
            drop=
            for e in $excl; do
                if [ "$name" = "$e" ] || [ "${name%.config}" = "$e" ] || [ "$core" = "$e" ]; then
                    drop=1
                    break
                fi
            done
            if [ -n "$drop" ]; then
                warn "defconfig fragment excluded: $name"
            else
                keep+=("$frag")
            fi
        done
        frags=${keep[*]}
    fi
    [ -n "$frags" ] || return 0

    local cfg=$WORK_DIR/build.config.cloudfox
    local arch defconfig
    arch=$(config_get "$cfg" ARCH)
    defconfig=$(config_get "$cfg" DEFCONFIG)
    arch=${arch:-arm64}
    defconfig=${defconfig:-gki_defconfig}
    local file=$WORK_DIR/$KERNEL_DIR/arch/$arch/configs/$defconfig
    [ -f "$file" ] || die "defconfig not found: $file"

    if [ -n "$APPEND_CONFIG" ]; then
        local lcf ap ifs_save
        lcf=$(mktemp)
        ifs_save=$IFS
        IFS=,
        for ap in $APPEND_CONFIG; do
            [ -n "$ap" ] || continue
            case "$ap" in
                CONFIG_*=*|'# CONFIG_'*' is not set')
                    printf '%s\n' "$ap" >> "$lcf" ;;
                *)
                    warn "append_config must be literal CONFIG_* lines; ignoring: $ap" ;;
            esac
        done
        IFS=$ifs_save
        if [ -s "$lcf" ]; then
            frags="$frags $lcf"
        else
            rm -f "$lcf"
        fi
    fi

    local start='# begin-cloudfox-fragment' end='# end-cloudfox-fragment'
    local stripped block out sym val cand line frag bad
    stripped=$(mktemp)
    block=$(mktemp)
    out=$(mktemp)
    awk -v s="$start" -v e="$end" '$0==s{skip=1;next} $0==e{skip=0;next} !skip' "$file" > "$stripped"

    local -A cfg
    while IFS= read -r line; do
        case "$line" in
            CONFIG_*=*|'# CONFIG_'*' is not set') cfg["$line"]=1 ;;
        esac
    done < "$file"

    {
        printf '\n%s\n' "$start"
        for frag in $frags; do
            [ -f "$frag" ] || die "defconfig fragment not found: $frag"
            bad=$(grep -nEv '^[[:space:]]*(#|$)|^CONFIG_' "$frag" || true)
            [ -z "$bad" ] || die "invalid lines in defconfig fragment \"$frag\":$(printf '\n%s' "$bad")"
            printf '# fragment: %s\n' "$frag"
            while IFS= read -r line; do
                case "$line" in
                    *' is not set') sym=${line#\# }; sym=${sym%' is not set'}; val= ;;
                    ''|'#'*)    continue ;;
                    CONFIG_*=*) sym=${line%%=*}; val=${line#*=} ;;
                    *) continue ;;
                esac
                if [ -n "$val" ]; then
                    cand="${sym}=${val}"
                else
                    cand="# ${sym} is not set"
                fi
                [[ -v "cfg[$cand]" ]] && continue
                printf '%s\n' "$line"
            done < "$frag"
        done
        printf '%s\n' "$end"
    } > "$block"

    if grep -qE '^CONFIG_|^# CONFIG_' "$block"; then
        cat "$stripped" "$block" > "$out"
        mv "$out" "$file"
        ok "appended defconfig fragment(s) to $(rel "$file")"
        commit_defconfig "$arch" "$defconfig" "apply CloudFox defconfig fragments"
    else
        ok "defconfig fragment(s): all symbols already effective"
        rm -f "$out"
    fi
    rm -f "$stripped" "$block"
}

commit_defconfig() { 
    local arch=$1 defconfig=$2 msg=$3
    local tree=$WORK_DIR/$KERNEL_DIR
    [ -d "$tree/.git" ] || return 0
    if git -C "$tree" -c user.name="${GIT_BUILDER_NAME:-CloudFox Kernel Builder}" \
            -c user.email="${GIT_BUILDER_EMAIL:-builder@localhost}" \
            commit -q --only -m "$msg: $defconfig" -- \
            "arch/$arch/configs/$defconfig" 2>/dev/null; then
        ok "committed $defconfig ($msg)"
    else
        warn "could not commit $defconfig"
    fi
}

run_build() {
    local config=${BUILD_CONFIG:-build.config.cloudfox}
    if [ -z "$BUILD_CONFIG" ]; then
        info "build config: $(rel "$WORK_DIR/build.config.cloudfox")"
    else
        info "build config: $config"
        [ -f "$WORK_DIR/$config" ] || die "build config not found: $WORK_DIR/$config"
    fi
    [ -n "$JOBS" ] && export MAKEFLAGS="-j$JOBS"
    
    local host_args=()
    if [ -n "$CLANG_URL" ] || [[ "${CLANG_ASSET:-}" == *"neutron"* ]]; then
        host_args+=(
            "HOSTCC=${CLOUDFOX_HOST_CC:-gcc}"
            "HOSTCXX=${CLOUDFOX_HOST_CXX:-g++}"
            "HOSTLD=ld"
            "HOSTAR=ar"
        )
        info "host tools will use ${CLOUDFOX_HOST_CC:-gcc}"
    fi

    export LTO="${LTO}"
    info "LTO mode set to: $LTO"
    export LLVM=1

    (cd "$WORK_DIR" && BUILD_CONFIG=$config ./build/build.sh "${host_args[@]}")
}

collect() {
    local dist_out config_out
    dist_out=$(find "$WORK_DIR/out" -maxdepth 4 -type d -name dist -print -quit 2>/dev/null || true)
    [ -n "$dist_out" ] || { warn "no dist dir under $WORK_DIR/out"; return; }
    local dist_dir=$WORK_DIR/dist
    rm -rf "$dist_dir"
    mv "$dist_out" "$dist_dir"
    if [ -f "$dist_dir/arch/arm64/boot/Image" ]; then
        if bash "$WORK_DIR/$KERNEL_DIR/scripts/extract-ikconfig" "$dist_dir/arch/arm64/boot/Image" > "$dist_dir/ikconfig" 2>/dev/null; then
            ok "ikconfig extracted"
        else
            warn "ikconfig extraction failed"
        fi
    fi
    config_out=$(find "$WORK_DIR/out" -maxdepth 3 -name .config -print -quit 2>/dev/null || true)
    [ -z "$config_out" ] || cp -a "$config_out" "$dist_dir/.config"
    ok "artifacts collected in $(rel "$dist_dir")"
}

main() {
    [ "$(readlink -f "$WORK_DIR")" != "$(readlink -f "$SCRIPT_DIR")" ] \
        || die "WORK_DIR must not be the script directory"
    if [ "$CLEAN" -eq 1 ]; then
        rm -rf "$WORK_DIR"
    fi
    mkdir -p "$WORK_DIR/downloads"
    info "work dir: $(rel "$WORK_DIR")"
    preflight
    if [ "$SKIP_FETCH" -eq 0 ]; then
        fetch_build_scripts
        local kernel_pid fetch_pids=() fetch_rc=0 pid clang_dl_pid
        fetch_kernel & kernel_pid=$!
        fetch_kernel_build_tools & fetch_pids+=("$!")
        fetch_build_tools & fetch_pids+=("$!")
        if [ -z "$CLANG_URL" ] && [ "${HERMETIC_TOOLCHAIN:-1}" != "0" ] && [[ "${CLANG_ASSET:-}" != *"neutron"* ]]; then
            fetch_gcc_host & fetch_pids+=("$!")
        fi
        fetch_gas & fetch_pids+=("$!")
        fetch_ccache & fetch_pids+=("$!")
        fetch_clang_download && fetch_clang_extract & clang_dl_pid=$!
        wait "$clang_dl_pid" || true
        if wait "$kernel_pid"; then
            fetch_clang & fetch_pids+=("$!")
        else
            fetch_rc=1
        fi
        for pid in "${fetch_pids[@]}"; do
            wait "$pid" || fetch_rc=1
        done
        [ "$fetch_rc" -eq 0 ] || die "one or more prebuilt fetches failed"
        verify_build_tools_links
        write_build_config
    else
        [ -x "$WORK_DIR/build/build.sh" ] || die "--skip-fetch requires an existing layout in $WORK_DIR"
    fi
    apply_defconfig_fragment
    if [ "$SKIP_BUILD" -eq 0 ]; then
        install_ccache_wrappers
        trap restore_ccache_wrappers EXIT
        run_build
        collect
        info "done. kernel and artifacts: $(rel "$WORK_DIR/dist")"
    else
        info "fetch phase done; layout ready in $(rel "$WORK_DIR")"
    fi
}

main "$@"
