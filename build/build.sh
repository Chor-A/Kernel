#!/bin/bash

set -e

OLD_ENVIRONMENT=$(mktemp)
export -p > ${OLD_ENVIRONMENT}

function rel_path() {
  local to=$1
  local from=$2
  local path=
  local stem=
  local prevstem=
  [ -n "$to" ] || return 1
  [ -n "$from" ] || return 1
  to=$(readlink -e "$to")
  from=$(readlink -e "$from")
  [ -n "$to" ] || return 1
  [ -n "$from" ] || return 1
  stem=${from}/
  while [ "${to#$stem}" == "${to}" -a "${stem}" != "${prevstem}" ]; do
    prevstem=$stem
    stem=$(readlink -e "${stem}/..")
    [ "${stem%/}" == "${stem}" ] && stem=${stem}/
    path=${path}../
  done
  echo ${path}${to#$stem}
}

function run_depmod() {
  (
    local ramdisk_dir=$1
    local DEPMOD_OUTPUT
    local version=$3
    local modules_list_file=$4
    local modules_list=""
    if [[ -n "${modules_list_file}" ]]; then
      while read -r line; do
        modules_list+="$(realpath ${ramdisk_dir}/lib/modules/${version}/${line}) "
      done <${modules_list_file}
    fi
    cd ${ramdisk_dir}
    if ! DEPMOD_OUTPUT="$(depmod $2 -F ${DIST_DIR}/System.map -b . ${version} ${modules_list} 2>&1)"; then
      echo "$DEPMOD_OUTPUT" >&2
      exit 1
    fi
    echo "$DEPMOD_OUTPUT"
    if { echo "$DEPMOD_OUTPUT" | grep -q "needs unknown symbol"; }; then
      echo "ERROR: kernel module(s) need unknown symbol(s)" >&2
      exit 1
    fi
  )
}

function create_modules_order_lists() {
  local modules_list_file="${1}"
  local modules_recovery_list_file="${2}"
  local modules_charger_list_file="${3}"
  local modules_order_list_file="${4}"
  local dest_dir=$(dirname $(realpath ${modules_order_list_file}))
  local tmp_modules_order_file=$(mktemp)
  cp ${modules_order_list_file} ${tmp_modules_order_file}
  declare -A module_lists_arr
  module_lists_arr["modules.order"]=${modules_list_file}
  module_lists_arr["modules.order.recovery"]=${modules_recovery_list_file}
  module_lists_arr["modules.order.charger"]=${modules_charger_list_file}
  for mod_order_file in ${!module_lists_arr[@]}; do
    local mod_list_file=${module_lists_arr[${mod_order_file}]}
    local dest_file=${dest_dir}/${mod_order_file}
    if [[ -n "${mod_list_file}" ]]; then
      echo "========================================================"
      echo " Reducing ${mod_order_file} to:"
      if [[ -f "${ROOT_DIR}/${mod_list_file}" ]]; then
        modules_list_file="${ROOT_DIR}/${mod_list_file}"
      elif [[ "${mod_list_file}" != /* ]]; then
        echo "ERROR: modules list must be an absolute path or relative to ${ROOT_DIR}: ${mod_list_file}" >&2
        rm -f ${tmp_modules_order_file}
        exit 1
      elif [[ ! -f "${mod_list_file}" ]]; then
        echo "ERROR: Failed to find modules list: ${mod_list_file}" >&2
        rm -f ${tmp_modules_order_file}
        exit 1
      fi
      local modules_list_filter=$(mktemp)
      ! grep -v "^\#" ${mod_list_file} > ${modules_list_filter}
      echo >> ${modules_list_filter}
      ! grep -w -f ${modules_list_filter} ${tmp_modules_order_file} > ${dest_file}
      rm -f ${modules_list_filter}
      cat ${dest_file} | sed -e "s/^/  /"
    fi
  done
  rm -f ${tmp_modules_order_file}
}

function create_modules_staging() {
  local modules_list_file=$1
  local src_dir=$(echo $2/lib/modules/*)
  local version=$(basename "${src_dir}")
  local dest_dir=$3/lib/modules/${version}
  local dest_stage=$3
  local modules_blocklist_file=$4
  local modules_recovery_list_file=$5
  local modules_charger_list_file=$6
  local depmod_flags=$7
  rm -rf ${dest_dir}
  mkdir -p ${dest_dir}/kernel
  find ${src_dir}/kernel/ -maxdepth 1 -mindepth 1 -exec cp -r {} ${dest_dir}/kernel/ \;
  cp ${src_dir}/modules.order ${dest_dir}/modules.order
  cp ${src_dir}/modules.builtin ${dest_dir}/modules.builtin
  if [[ -n "${EXT_MODULES}" ]] || [[ -n "${EXT_MODULES_MAKEFILE}" ]]; then
    mkdir -p ${dest_dir}/extra/
    cp -r ${src_dir}/extra/* ${dest_dir}/extra/
    (cd ${dest_dir}/ && find extra -type f -name "*.ko" | sort >> modules.order)
  fi
  if [ "${DO_NOT_STRIP_MODULES}" = "1" ]; then
    find ${dest_dir} -type f -name "*.ko" -exec ${OBJCOPY:-${CROSS_COMPILE}objcopy} --strip-debug {} \;
  fi
  create_modules_order_lists "${modules_list_file:-""}" "${modules_recovery_list_file:-""}" \
                         "${modules_charger_list_file:-""}" ${dest_dir}/modules.order
  if [ -n "${modules_blocklist_file}" ]; then
    if [[ -f "${ROOT_DIR}/${modules_blocklist_file}" ]]; then
      modules_blocklist_file="${ROOT_DIR}/${modules_blocklist_file}"
    elif [[ "${modules_blocklist_file}" != /* ]]; then
      echo "modules blocklist must be an absolute path or relative to ${ROOT_DIR}: ${modules_blocklist_file}"
      exit 1
    elif [[ ! -f "${modules_blocklist_file}" ]]; then
      echo "Failed to find modules blocklist: ${modules_blocklist_file}"
      exit 1
    fi
    cp ${modules_blocklist_file} ${dest_dir}/modules.blocklist
  fi
  if [ -n "${TRIM_UNUSED_MODULES}" ]; then
    echo "========================================================"
    echo " Trimming unused modules"
    local used_blocklist_modules=$(mktemp)
    if [ -f ${dest_dir}/modules.blocklist ]; then
      sed -n -E -e 's/blocklist (.+)/\1/p' ${dest_dir}/modules.blocklist > $used_blocklist_modules
    fi
    (
      cd ${dest_dir}
      local grep_flags="-v -w -f modules.order -f ${used_blocklist_modules} "
      if [[ -f modules.order.recovery ]]; then
        grep_flags+="-f modules.order.recovery "
      fi
      if [[ -f modules.order.charger ]]; then
        grep_flags+="-f modules.order.charger "
      fi
      find * -type f -name "*.ko" | (grep ${grep_flags} - || true) | xargs -r rm
    )
    rm $used_blocklist_modules
  fi
  modules_order_files=("modules.order.recovery" "modules.order.charger" "modules.order")
  modules_load_files=("modules.load.recovery" "modules.load.charger" "modules.load")
  for i in ${!modules_order_files[@]}; do
    local mod_order_filepath=${dest_dir}/${modules_order_files[$i]}
    local mod_load_filepath=${dest_dir}/${modules_load_files[$i]}
    if [[ -f ${mod_order_filepath} ]]; then
      if [[ "${modules_order_files[$i]}" == "modules.order" ]]; then
        run_depmod ${dest_stage} "${depmod_flags}" "${version}"
      else
        run_depmod ${dest_stage} "${depmod_flags}" "${version}" "${mod_order_filepath}"
      fi
      cp ${mod_order_filepath} ${mod_load_filepath}
    fi
  done
}

function build_vendor_dlkm() {
  echo "========================================================"
  echo " Creating vendor_dlkm image"
  create_modules_staging "${VENDOR_DLKM_MODULES_LIST}" "${MODULES_STAGING_DIR}" \
    "${VENDOR_DLKM_STAGING_DIR}" "${VENDOR_DLKM_MODULES_BLOCKLIST}"
  local vendor_dlkm_modules_root_dir=$(echo ${VENDOR_DLKM_STAGING_DIR}/lib/modules/*)
  local vendor_dlkm_modules_load=${vendor_dlkm_modules_root_dir}/modules.load
  if [ -f ${vendor_dlkm_modules_root_dir}/modules.blocklist ]; then
    cp ${vendor_dlkm_modules_root_dir}/modules.blocklist ${DIST_DIR}/vendor_dlkm.modules.blocklist
  fi
  if [ -f ${DIST_DIR}/vendor_boot.modules.load ]; then
    local stripped_modules_load="$(mktemp)"
    ! grep -x -v -F -f ${DIST_DIR}/vendor_boot.modules.load \
      ${vendor_dlkm_modules_load} > ${stripped_modules_load}
    mv -f ${stripped_modules_load} ${vendor_dlkm_modules_load}
  fi
  cp ${vendor_dlkm_modules_load} ${DIST_DIR}/vendor_dlkm.modules.load
  local vendor_dlkm_props_file
  if [ -z "${VENDOR_DLKM_PROPS}" ]; then
    vendor_dlkm_props_file="$(mktemp)"
    echo -e "vendor_dlkm_fs_type=ext4\n" >> ${vendor_dlkm_props_file}
    echo -e "use_dynamic_partition_size=true\n" >> ${vendor_dlkm_props_file}
    echo -e "ext_mkuserimg=mkuserimg_mke2fs\n" >> ${vendor_dlkm_props_file}
    echo -e "ext4_share_dup_blocks=true\n" >> ${vendor_dlkm_props_file}
  else
    vendor_dlkm_props_file="${VENDOR_DLKM_PROPS}"
    if [[ -f "${ROOT_DIR}/${vendor_dlkm_props_file}" ]]; then
      vendor_dlkm_props_file="${ROOT_DIR}/${vendor_dlkm_props_file}"
    elif [[ "${vendor_dlkm_props_file}" != /* ]]; then
      echo "VENDOR_DLKM_PROPS must be an absolute path or relative to ${ROOT_DIR}: ${vendor_dlkm_props_file}"
      exit 1
    elif [[ ! -f "${vendor_dlkm_props_file}" ]]; then
      echo "Failed to find VENDOR_DLKM_PROPS: ${vendor_dlkm_props_file}"
      exit 1
    fi
  fi
  build_image "${VENDOR_DLKM_STAGING_DIR}" "${vendor_dlkm_props_file}" \
    "${DIST_DIR}/vendor_dlkm.img" /dev/null
}

export ROOT_DIR=$(readlink -f $(dirname $0)/..)

echo "::group::[*] Downloading Clang"
CLANG_BIN="${ROOT_DIR}/neutron-clang/bin"
mkdir -p "${ROOT_DIR}/neutron-clang"
cd "${ROOT_DIR}/neutron-clang"
bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") -S
./antman --patch=glibc
cd $OLDPWD

if [ ! -d "$CLANG_BIN" ]; then
    echo "[-] Clang not found in ${CLANG_BIN}."
    exit 1
fi

export PATH="${CLANG_BIN}:$PATH"
export CCACHE_DIR="$HOME/.ccache"
export CCACHE_BASEDIR="${ROOT_DIR}"
export CCACHE_NOHARDLINK=true
export CCACHE_COMPILERCHECK=content
export CC="ccache clang"
export CXX="ccache clang++"
export LLVM=1
export LTO="full"

ccache --zero-stats
ccache --max-size=5G
ccache --set-config=sloppiness="pch_defines,time_macros,file_macro,include_file_mtime,include_file_ctime"
ccache --set-config=hash_dir=false
ccache --set-config=base_dir="${ROOT_DIR}"
ccache --set-config=compiler_check=content

COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')
echo "COMPILER_STRING=$COMPILER_STRING"
echo "::endgroup::"

FILE_SIGN_BIN=scripts/sign-file
SIGN_SEC=certs/signing_key.pem
SIGN_CERT=certs/signing_key.x509
SIGN_ALGO=sha512

CC_ARG="${CC}"

source "${ROOT_DIR}/build/_setup_env.sh"

MAKE_ARGS=( "$@" )
export MAKEFLAGS="-j$(nproc) ${MAKEFLAGS}"
export MODULES_STAGING_DIR=$(readlink -m ${COMMON_OUT_DIR}/staging)
export MODULES_PRIVATE_DIR=$(readlink -m ${COMMON_OUT_DIR}/private)
export KERNEL_UAPI_HEADERS_DIR=$(readlink -m ${COMMON_OUT_DIR}/kernel_uapi_headers)
export INITRAMFS_STAGING_DIR=${MODULES_STAGING_DIR}/initramfs_staging
export VENDOR_DLKM_STAGING_DIR=${MODULES_STAGING_DIR}/vendor_dlkm_staging
export MKBOOTIMG_STAGING_DIR="${MODULES_STAGING_DIR}/mkbootimg_staging"

if [ -n "${SKIP_VENDOR_BOOT}" -a -n "${BUILD_VENDOR_BOOT_IMG}" ]; then
  echo "ERROR: SKIP_VENDOR_BOOT is incompatible with BUILD_VENDOR_BOOT_IMG." >&2
  exit 1
fi

if [ -n "${GKI_BUILD_CONFIG}" ]; then
  if [ -n "${GKI_PREBUILTS_DIR}" ]; then
      echo "ERROR: GKI_BUILD_CONFIG is incompatible with GKI_PREBUILTS_DIR." >&2
      exit 1
  fi
  GKI_OUT_DIR=${GKI_OUT_DIR:-${COMMON_OUT_DIR}/gki_kernel}
  GKI_DIST_DIR=${GKI_DIST_DIR:-${GKI_OUT_DIR}/dist}
  if [[ "${MAKE_GOALS}" =~ image|Image|vmlinux ]]; then
    echo " Compiling Image and vmlinux in device kernel is not supported in mixed build mode"
    exit 1
  fi
  GKI_ENVIRON=("SKIP_MRPROPER=${SKIP_MRPROPER}" "LTO=${LTO}" "SKIP_DEFCONFIG=${SKIP_DEFCONFIG}" "SKIP_IF_VERSION_MATCHES=${SKIP_IF_VERSION_MATCHES}")
  GKI_ENVIRON+=("EXT_MODULES=")
  GKI_ENVIRON+=("GKI_BUILD_CONFIG=")
  GKI_ENVIRON+=($(export -p | sed -n -E -e 's/.* GKI_([^=]+=.*)$/\1/p' | tr '\n' ' '))
  GKI_ENVIRON+=("OUT_DIR=${GKI_OUT_DIR}")
  GKI_ENVIRON+=("DIST_DIR=${GKI_DIST_DIR}")
  ( env -i bash -c "source ${OLD_ENVIRONMENT}; rm -f ${OLD_ENVIRONMENT}; export ${GKI_ENVIRON[*]} ; ./build/build.sh" ) || exit 1
  MAKE_ARGS+=("KBUILD_MIXED_TREE=$(readlink -m ${GKI_DIST_DIR})")
else
  rm -f ${OLD_ENVIRONMENT}
fi

BOOT_IMAGE_HEADER_VERSION=${BOOT_IMAGE_HEADER_VERSION:-3}

if [ -n "${DTS_EXT_DIR}" ]; then
  if [[ "${MAKE_GOALS}" =~ dtbs|\.dtb|\.dtbo ]]; then
    if [ -d "${ROOT_DIR}/${DTS_EXT_DIR}" ]; then
      DTS_EXT_DIR=$(rel_path ${ROOT_DIR}/${DTS_EXT_DIR} ${KERNEL_DIR})
    elif [ ! -d "${KERNEL_DIR}/${DTS_EXT_DIR}" ]; then
      echo "Couldn't find the dtstree -- ${DTS_EXT_DIR}" >&2
      exit 1
    fi
    MAKE_ARGS+=("dtstree=${DTS_EXT_DIR}")
  fi
fi

cd ${ROOT_DIR}

export CLANG_TRIPLE CROSS_COMPILE CROSS_COMPILE_COMPAT CROSS_COMPILE_ARM32 ARCH SUBARCH MAKE_GOALS

[ -n "${CC_ARG}" ] && CC="${CC_ARG}"

[ "${CC}" == "gcc" ] && unset CC && unset CC_ARG

TOOL_ARGS=()

if [[ -n "${LLVM}" ]]; then
  TOOL_ARGS+=("LLVM=1")
  HOSTCC=clang
  HOSTCXX=clang++
  CC=clang
  LD=ld.lld
  AR=llvm-ar
  NM=llvm-nm
  OBJCOPY=llvm-objcopy
  OBJDUMP=llvm-objdump
  READELF=llvm-readelf
  OBJSIZE=llvm-size
  STRIP=llvm-strip
else
  if [ -n "${HOSTCC}" ]; then
    TOOL_ARGS+=("HOSTCC=${HOSTCC}")
  fi
  if [ -n "${CC}" ]; then
    TOOL_ARGS+=("CC=${CC}")
    if [ -z "${HOSTCC}" ]; then
      TOOL_ARGS+=("HOSTCC=${CC}")
    fi
  fi
  if [ -n "${LD}" ]; then
    TOOL_ARGS+=("LD=${LD}" "HOSTLD=${LD}")
  fi
  if [ -n "${NM}" ]; then
    TOOL_ARGS+=("NM=${NM}")
  fi
  if [ -n "${OBJCOPY}" ]; then
    TOOL_ARGS+=("OBJCOPY=${OBJCOPY}")
  fi
fi

if [ -n "${LLVM_IAS}" ]; then
  TOOL_ARGS+=("LLVM_IAS=${LLVM_IAS}")
  AS=clang
fi

if [ -n "${DEPMOD}" ]; then
  TOOL_ARGS+=("DEPMOD=${DEPMOD}")
fi

if [ -n "${DTC}" ]; then
  TOOL_ARGS+=("DTC=${DTC}")
fi

CC_LD_ARG="${TOOL_ARGS[@]}"

DECOMPRESS_GZIP="gzip -c -d"
DECOMPRESS_LZ4="lz4 -c -d -l"
if [ -z "${LZ4_RAMDISK}" ] ; then
  RAMDISK_COMPRESS="gzip -c -f"
  RAMDISK_DECOMPRESS="${DECOMPRESS_GZIP}"
  RAMDISK_EXT="gz"
else
  RAMDISK_COMPRESS="lz4 -c -l -12 --favor-decSpeed"
  RAMDISK_DECOMPRESS="${DECOMPRESS_LZ4}"
  RAMDISK_EXT="lz4"
fi

if [ -n "${SKIP_IF_VERSION_MATCHES}" ]; then
  if [ -f "${DIST_DIR}/vmlinux" ]; then
    kernelversion="$(cd ${KERNEL_DIR} && make -s "${TOOL_ARGS[@]}" O=${OUT_DIR} kernelrelease)"
    if [[ ! "$kernelversion" =~ .*dirty.* ]] && \
       grep -o -a -m2 "Linux version [^ ]* " ${DIST_DIR}/vmlinux | grep -q " ${kernelversion} " ; then
      echo "========================================================"
      echo " Skipping build because kernel version matches ${kernelversion}"
      exit 0
    fi
  fi
fi

mkdir -p ${OUT_DIR} ${DIST_DIR}

if [ -n "${GKI_PREBUILTS_DIR}" ]; then
  echo "========================================================"
  echo " Copying GKI prebuilts"
  GKI_PREBUILTS_DIR=$(readlink -m ${GKI_PREBUILTS_DIR})
  if [ ! -d "${GKI_PREBUILTS_DIR}" ]; then
    echo "ERROR: ${GKI_PREBULTS_DIR} does not exist." >&2
    exit 1
  fi
  for file in ${GKI_PREBUILTS_DIR}/*; do
    filename=$(basename ${file})
    if ! $(cmp -s ${file} ${DIST_DIR}/${filename}); then
      cp -v ${file} ${DIST_DIR}/${filename}
    fi
  done
  MAKE_ARGS+=("KBUILD_MIXED_TREE=${GKI_PREBUILTS_DIR}")
fi

echo "========================================================"
echo " Setting up for build"
if [ "${SKIP_MRPROPER}" != "1" ] ; then
  set -x
  (cd ${KERNEL_DIR} && make "${TOOL_ARGS[@]}" O=${OUT_DIR} "${MAKE_ARGS[@]}" mrproper)
  set +x
fi

if [ -n "${PRE_DEFCONFIG_CMDS}" ]; then
  echo "========================================================"
  echo " Running pre-defconfig command(s):"
  set -x
  eval ${PRE_DEFCONFIG_CMDS}
  set +x
fi

if [ "${SKIP_DEFCONFIG}" != "1" ] ; then
  set -x
  (cd ${KERNEL_DIR} && make "${TOOL_ARGS[@]}" O=${OUT_DIR} "${MAKE_ARGS[@]}" ${DEFCONFIG})
  set +x
  if [ -n "${POST_DEFCONFIG_CMDS}" ]; then
    echo "========================================================"
    echo " Running pre-make command(s):"
    set -x
    eval ${POST_DEFCONFIG_CMDS}
    set +x
  fi
fi

if [ "${LTO}" = "none" -o "${LTO}" = "thin" -o "${LTO}" = "full" ]; then
  echo "========================================================"
  echo " Modifying LTO mode to '${LTO}'"
  set -x
  if [ "${LTO}" = "none" ]; then
    ${KERNEL_DIR}/scripts/config --file ${OUT_DIR}/.config \
      -d LTO_CLANG \
      -e LTO_NONE \
      -d LTO_CLANG_THIN \
      -d LTO_CLANG_FULL \
      -d THINLTO
  elif [ "${LTO}" = "thin" ]; then
    ${KERNEL_DIR}/scripts/config --file ${OUT_DIR}/.config \
      -e LTO_CLANG \
      -d LTO_NONE \
      -e LTO_CLANG_THIN \
      -d LTO_CLANG_FULL \
      -e THINLTO
  elif [ "${LTO}" = "full" ]; then
    ${KERNEL_DIR}/scripts/config --file ${OUT_DIR}/.config \
      -e LTO_CLANG \
      -d LTO_NONE \
      -d LTO_CLANG_THIN \
      -e LTO_CLANG_FULL \
      -d THINLTO
  fi
  (cd ${OUT_DIR} && make "${TOOL_ARGS[@]}" O=${OUT_DIR} "${MAKE_ARGS[@]}" olddefconfig)
  set +x
elif [ -n "${LTO}" ]; then
  echo "LTO= must be one of 'none', 'thin' or 'full'."
  exit 1
fi

if [ -n "${TAGS_CONFIG}" ]; then
  echo "========================================================"
  echo " Running tags command:"
  set -x
  (cd ${KERNEL_DIR} && SRCARCH=${ARCH} ./scripts/tags.sh ${TAGS_CONFIG})
  set +x
  exit 0
fi

ABI_PROP=${DIST_DIR}/abi.prop
: > ${ABI_PROP}

if [ -n "${ABI_DEFINITION}" ]; then
  ABI_XML=${DIST_DIR}/abi.xml
  echo "KMI_DEFINITION=abi.xml" >> ${ABI_PROP}
  echo "KMI_MONITORED=1"        >> ${ABI_PROP}
  if [ "${KMI_ENFORCED}" = "1" ]; then
    echo "KMI_ENFORCED=1" >> ${ABI_PROP}
  fi
fi

if [ -n "${KMI_SYMBOL_LIST}" ]; then
  ABI_SL=${DIST_DIR}/abi_symbollist
  echo "KMI_SYMBOL_LIST=abi_symbollist" >> ${ABI_PROP}
fi

echo "KERNEL_BINARY=vmlinux" >> ${ABI_PROP}
if [ "${COMPRESS_UNSTRIPPED_MODULES}" = "1" ]; then
  echo "MODULES_ARCHIVE=${UNSTRIPPED_MODULES_ARCHIVE}" >> ${ABI_PROP}
fi

if [ -n "${ABI_DEFINITION}" ]; then
  echo "========================================================"
  echo " Copying abi definition to ${ABI_XML}"
  pushd $ROOT_DIR/$KERNEL_DIR
    cp "${ABI_DEFINITION}" ${ABI_XML}
  popd
fi

if [ -n "${KMI_SYMBOL_LIST}" ]; then
  ${ROOT_DIR}/build/copy_symbols.sh "$ABI_SL" "$ROOT_DIR/$KERNEL_DIR" \
    "${KMI_SYMBOL_LIST}" ${ADDITIONAL_KMI_SYMBOL_LISTS}
  pushd $ROOT_DIR/$KERNEL_DIR
  if [ "${TRIM_NONLISTED_KMI}" = "1" ]; then
      cat ${ABI_SL} | \
              ${ROOT_DIR}/build/abi/flatten_symbol_list > \
              ${OUT_DIR}/abi_symbollist.raw
      ./scripts/config --file ${OUT_DIR}/.config \
              -d UNUSED_SYMBOLS -e TRIM_UNUSED_KSYMS \
              --set-str UNUSED_KSYMS_WHITELIST ${OUT_DIR}/abi_symbollist.raw
      (cd ${OUT_DIR} && \
              make O=${OUT_DIR} "${TOOL_ARGS[@]}" "${MAKE_ARGS[@]}" olddefconfig)
      grep CONFIG_UNUSED_KSYMS_WHITELIST ${OUT_DIR}/.config > /dev/null || {
        echo "ERROR: Failed to apply TRIM_NONLISTED_KMI kernel configuration" >&2
        echo "Does your kernel support CONFIG_UNUSED_KSYMS_WHITELIST?" >&2
        exit 1
      }
    elif [ "${KMI_SYMBOL_LIST_STRICT_MODE}" = "1" ]; then
      echo "ERROR: KMI_SYMBOL_LIST_STRICT_MODE requires TRIM_NONLISTED_KMI=1" >&2
    exit 1
  fi
  popd
elif [ "${TRIM_NONLISTED_KMI}" = "1" ]; then
  echo "ERROR: TRIM_NONLISTED_KMI requires a KMI_SYMBOL_LIST" >&2
  exit 1
elif [ "${KMI_SYMBOL_LIST_STRICT_MODE}" = "1" ]; then
  echo "ERROR: KMI_SYMBOL_LIST_STRICT_MODE requires a KMI_SYMBOL_LIST" >&2
  exit 1
fi

echo "========================================================"
echo " Building kernel"

set -x
(cd ${OUT_DIR} && make O=${OUT_DIR} "${TOOL_ARGS[@]}" "${MAKE_ARGS[@]}" ${MAKE_GOALS})
set +x

if [ -n "${POST_KERNEL_BUILD_CMDS}" ]; then
  echo "========================================================"
  echo " Running post-kernel-build command(s):"
  set -x
  eval ${POST_KERNEL_BUILD_CMDS}
  set +x
fi

if [ -n "${MODULES_ORDER}" ]; then
  echo "========================================================"
  echo " Checking the list of modules:"
  if ! diff -u "${KERNEL_DIR}/${MODULES_ORDER}" "${OUT_DIR}/modules.order"; then
    echo "ERROR: modules list out of date" >&2
    echo "Update it with:" >&2
    echo "cp ${OUT_DIR}/modules.order ${KERNEL_DIR}/${MODULES_ORDER}" >&2
    exit 1
  fi
fi

if [ "${KMI_SYMBOL_LIST_STRICT_MODE}" = "1" ]; then
  echo "========================================================"
  echo " Comparing the KMI and the symbol lists:"
  set -x
  ${ROOT_DIR}/build/abi/compare_to_symbol_list "${OUT_DIR}/Module.symvers" \
                                               "${OUT_DIR}/abi_symbollist.raw"
  set +x
fi

rm -rf ${MODULES_STAGING_DIR}
mkdir -p ${MODULES_STAGING_DIR}

if [ "${DO_NOT_STRIP_MODULES}" != "1" ]; then
  MODULE_STRIP_FLAG="INSTALL_MOD_STRIP=1"
fi

if [ "${BUILD_INITRAMFS}" = "1" -o  -n "${IN_KERNEL_MODULES}" ]; then
  echo "========================================================"
  echo " Installing kernel modules into staging directory"
  (cd ${OUT_DIR} &&                                                           \
   make O=${OUT_DIR} "${TOOL_ARGS[@]}" ${MODULE_STRIP_FLAG}                   \
        INSTALL_MOD_PATH=${MODULES_STAGING_DIR} "${MAKE_ARGS[@]}" modules_install)
fi

if [[ -z "${SKIP_EXT_MODULES}" ]] && [[ -n "${EXT_MODULES_MAKEFILE}" ]]; then
  echo "========================================================"
  echo " Building and installing external modules using ${EXT_MODULES_MAKEFILE}"
  make -f "${EXT_MODULES_MAKEFILE}" KERNEL_SRC=${ROOT_DIR}/${KERNEL_DIR} \
          O=${OUT_DIR} ${TOOL_ARGS} ${MODULE_STRIP_FLAG}                 \
          INSTALL_HDR_PATH="${KERNEL_UAPI_HEADERS_DIR}/usr"              \
          INSTALL_MOD_PATH=${MODULES_STAGING_DIR} "${MAKE_ARGS[@]}"
fi

if [[ -z "${SKIP_EXT_MODULES}" ]] && [[ -n "${EXT_MODULES}" ]]; then
  echo "========================================================"
  echo " Building external modules and installing them into staging directory"
  for EXT_MOD in ${EXT_MODULES}; do
    EXT_MOD_REL=$(rel_path ${ROOT_DIR}/${EXT_MOD} ${KERNEL_DIR})
    mkdir -p ${OUT_DIR}/${EXT_MOD_REL}
    set -x
    make -C ${EXT_MOD} M=${EXT_MOD_REL} KERNEL_SRC=${ROOT_DIR}/${KERNEL_DIR}  \
                       O=${OUT_DIR} "${TOOL_ARGS[@]}" "${MAKE_ARGS[@]}"
    make -C ${EXT_MOD} M=${EXT_MOD_REL} KERNEL_SRC=${ROOT_DIR}/${KERNEL_DIR}  \
                       O=${OUT_DIR} "${TOOL_ARGS[@]}" ${MODULE_STRIP_FLAG}    \
                       INSTALL_MOD_PATH=${MODULES_STAGING_DIR}                \
                       INSTALL_HDR_PATH="${KERNEL_UAPI_HEADERS_DIR}/usr"      \
                       "${MAKE_ARGS[@]}" modules_install
    set +x
  done
fi

echo "========================================================"
echo " Generating test_mappings.zip"
TEST_MAPPING_FILES=${OUT_DIR}/test_mapping_files.txt
find ${ROOT_DIR} -name TEST_MAPPING \
  -not -path "${ROOT_DIR}/\.git*" \
  -not -path "${ROOT_DIR}/\.repo*" \
  -not -path "${ROOT_DIR}/out*" \
  > ${TEST_MAPPING_FILES}
soong_zip -o ${DIST_DIR}/test_mappings.zip -C ${ROOT_DIR} -l ${TEST_MAPPING_FILES}

if [ -n "${EXTRA_CMDS}" ]; then
  echo "========================================================"
  echo " Running extra build command(s):"
  set -x
  eval ${EXTRA_CMDS}
  set +x
fi

OVERLAYS_OUT=""
for ODM_DIR in ${ODM_DIRS}; do
  OVERLAY_DIR=${ROOT_DIR}/device/${ODM_DIR}/overlays
  if [ -d ${OVERLAY_DIR} ]; then
    OVERLAY_OUT_DIR=${OUT_DIR}/overlays/${ODM_DIR}
    mkdir -p ${OVERLAY_OUT_DIR}
    make -C ${OVERLAY_DIR} DTC=${OUT_DIR}/scripts/dtc/dtc                     \
                           OUT_DIR=${OVERLAY_OUT_DIR} "${MAKE_ARGS[@]}"
    OVERLAYS=$(find ${OVERLAY_OUT_DIR} -name "*.dtbo")
    OVERLAYS_OUT="$OVERLAYS_OUT $OVERLAYS"
  fi
done

echo "========================================================"
echo " Copying files"
for FILE in $(cd ${OUT_DIR} && ls -1 ${FILES}); do
  if [ -f ${OUT_DIR}/${FILE} ]; then
    echo "  $FILE"
    cp -p ${OUT_DIR}/${FILE} ${DIST_DIR}/
  else
    echo "  $FILE is not a file, skipping"
  fi
done

for FILE in ${OVERLAYS_OUT}; do
  OVERLAY_DIST_DIR=${DIST_DIR}/$(dirname ${FILE#${OUT_DIR}/overlays/})
  echo "  ${FILE#${OUT_DIR}/}"
  mkdir -p ${OVERLAY_DIST_DIR}
  cp ${FILE} ${OVERLAY_DIST_DIR}/
done

if [ -z "${SKIP_CP_KERNEL_HDR}" ]; then
  echo "========================================================"
  echo " Installing UAPI kernel headers:"
  mkdir -p "${KERNEL_UAPI_HEADERS_DIR}/usr"
  make -C ${OUT_DIR} O=${OUT_DIR} "${TOOL_ARGS[@]}"                           \
          INSTALL_HDR_PATH="${KERNEL_UAPI_HEADERS_DIR}/usr" "${MAKE_ARGS[@]}"      \
          headers_install
  find ${KERNEL_UAPI_HEADERS_DIR} \( -name ..install.cmd -o -name .install \) -exec rm '{}' +
  KERNEL_UAPI_HEADERS_TAR=${DIST_DIR}/kernel-uapi-headers.tar.gz
  echo " Copying kernel UAPI headers to ${KERNEL_UAPI_HEADERS_TAR}"
  tar -czf ${KERNEL_UAPI_HEADERS_TAR} --directory=${KERNEL_UAPI_HEADERS_DIR} usr/
fi

if [ -z "${SKIP_CP_KERNEL_HDR}" ] ; then
  echo "========================================================"
  KERNEL_HEADERS_TAR=${DIST_DIR}/kernel-headers.tar.gz
  echo " Copying kernel headers to ${KERNEL_HEADERS_TAR}"
  pushd $ROOT_DIR/$KERNEL_DIR
    find arch include $OUT_DIR -name *.h -print0               \
            | tar -czf $KERNEL_HEADERS_TAR                     \
              --absolute-names                                 \
              --dereference                                    \
              --transform "s,.*$OUT_DIR,,"                     \
              --transform "s,^,kernel-headers/,"               \
              --null -T -
  popd
fi

if [ "${GENERATE_VMLINUX_BTF}" = "1" ]; then
  echo "========================================================"
  echo " Generating ${DIST_DIR}/vmlinux.btf"
  (
    cd ${DIST_DIR}
    cp -a vmlinux vmlinux.btf
    pahole -J vmlinux.btf
    llvm-strip --strip-debug vmlinux.btf
  )
fi

if [ -n "${GKI_DIST_DIR}" ]; then
  echo "========================================================"
  echo " Copying files from GKI kernel"
  cp -rv ${GKI_DIST_DIR}/* ${DIST_DIR}/
fi

if [ -n "${DIST_CMDS}" ]; then
  echo "========================================================"
  echo " Running extra dist command(s):"
  if [ ! -d "${KERNEL_UAPI_HEADERS_DIR}/usr" ]; then
    echo "WARN: running without UAPI headers"
  fi
  set -x
  eval ${DIST_CMDS}
  set +x
fi

MODULES=$(find ${MODULES_STAGING_DIR} -type f -name "*.ko")
if [ -n "${MODULES}" ]; then
  if [ -n "${IN_KERNEL_MODULES}" -o -n "${EXT_MODULES}" -o -n "${EXT_MODULES_MAKEFILE}" ]; then
    echo "========================================================"
    echo " Copying modules files"
    for FILE in ${MODULES}; do
      echo "  ${FILE#${MODULES_STAGING_DIR}/}"
      cp -p ${FILE} ${DIST_DIR}
    done
  fi
  if [ "${BUILD_INITRAMFS}" = "1" ]; then
    echo "========================================================"
    echo " Creating initramfs"
    rm -rf ${INITRAMFS_STAGING_DIR}
    create_modules_staging "${MODULES_LIST}" ${MODULES_STAGING_DIR} \
      ${INITRAMFS_STAGING_DIR} "${MODULES_BLOCKLIST}" "${MODULES_RECOVERY_LIST:-""}" \
      "${MODULES_CHARGER_LIST:-""}" "-e"
    MODULES_ROOT_DIR=$(echo ${INITRAMFS_STAGING_DIR}/lib/modules/*)
    MODULES_LOAD_FILES=( "modules.load" "modules.load.recovery" "modules.load.charger" )
    for file in "${MODULES_LOAD_FILES[@]}"; do
      [ -f ${MODULES_ROOT_DIR}/${file} ] && cp ${MODULES_ROOT_DIR}/${file} ${DIST_DIR}/${file}
      [ -f ${MODULES_ROOT_DIR}/${file} ] && cp ${MODULES_ROOT_DIR}/${file} ${DIST_DIR}/vendor_boot.${file}
    done
    echo "${MODULES_OPTIONS}" > ${MODULES_ROOT_DIR}/modules.options
    mkbootfs "${INITRAMFS_STAGING_DIR}" >"${MODULES_STAGING_DIR}/initramfs.cpio"
    ${RAMDISK_COMPRESS} "${MODULES_STAGING_DIR}/initramfs.cpio" >"${DIST_DIR}/initramfs.img"
  fi
fi

if [ -n "${VENDOR_DLKM_MODULES_LIST}" ]; then
  build_vendor_dlkm
fi

if [ -n "${UNSTRIPPED_MODULES}" ]; then
  echo "========================================================"
  echo " Copying unstripped module files for debugging purposes (not loaded on device)"
  mkdir -p ${UNSTRIPPED_DIR}
  for MODULE in ${UNSTRIPPED_MODULES}; do
    find ${MODULES_PRIVATE_DIR} -name ${MODULE} -exec cp {} ${UNSTRIPPED_DIR} \;
  done
  if [ "${COMPRESS_UNSTRIPPED_MODULES}" = "1" ]; then
    tar -czf ${DIST_DIR}/${UNSTRIPPED_MODULES_ARCHIVE} -C $(dirname ${UNSTRIPPED_DIR}) $(basename ${UNSTRIPPED_DIR})
    rm -rf ${UNSTRIPPED_DIR}
  fi
fi

[ -n "${GKI_MODULES_LIST}" ] && cp ${KERNEL_DIR}/${GKI_MODULES_LIST} ${DIST_DIR}/

echo "========================================================"
echo " Files copied to ${DIST_DIR}"

if [ -n "${BUILD_BOOT_IMG}" -o -n "${BUILD_VENDOR_BOOT_IMG}" ] ; then
  if [ -z "${MKBOOTIMG_PATH}" ]; then
    MKBOOTIMG_PATH="tools/mkbootimg/mkbootimg.py"
  fi
  if [ ! -f "${MKBOOTIMG_PATH}" ]; then
    echo "mkbootimg.py script not found. MKBOOTIMG_PATH = ${MKBOOTIMG_PATH}"
    exit 1
  fi
  MKBOOTIMG_ARGS=("--header_version" "${BOOT_IMAGE_HEADER_VERSION}")
  if [ -n  "${BASE_ADDRESS}" ]; then
    MKBOOTIMG_ARGS+=("--base" "${BASE_ADDRESS}")
  fi
  if [ -n  "${PAGE_SIZE}" ]; then
    MKBOOTIMG_ARGS+=("--pagesize" "${PAGE_SIZE}")
  fi
  if [ -n "${KERNEL_VENDOR_CMDLINE}" -a "${BOOT_IMAGE_HEADER_VERSION}" -lt "3" ]; then
    KERNEL_CMDLINE+=" ${KERNEL_VENDOR_CMDLINE}"
  fi
  if [ -n "${KERNEL_CMDLINE}" ]; then
    MKBOOTIMG_ARGS+=("--cmdline" "${KERNEL_CMDLINE}")
  fi
  if [ -n "${TAGS_OFFSET}" ]; then
    MKBOOTIMG_ARGS+=("--tags_offset" "${TAGS_OFFSET}")
  fi
  if [ -n "${RAMDISK_OFFSET}" ]; then
    MKBOOTIMG_ARGS+=("--ramdisk_offset" "${RAMDISK_OFFSET}")
  fi
  DTB_FILE_LIST=$(find ${DIST_DIR} -name "*.dtb" | sort)
  if [ -z "${DTB_FILE_LIST}" ]; then
    if [ -z "${SKIP_VENDOR_BOOT}" ]; then
      echo "No *.dtb files found in ${DIST_DIR}"
      exit 1
    fi
  else
    cat $DTB_FILE_LIST > ${DIST_DIR}/dtb.img
    MKBOOTIMG_ARGS+=("--dtb" "${DIST_DIR}/dtb.img")
  fi
  rm -rf "${MKBOOTIMG_STAGING_DIR}"
  MKBOOTIMG_RAMDISK_STAGING_DIR="${MKBOOTIMG_STAGING_DIR}/ramdisk_root"
  mkdir -p "${MKBOOTIMG_RAMDISK_STAGING_DIR}"
  if [ -n "${VENDOR_RAMDISK_BINARY}" ]; then
    VENDOR_RAMDISK_CPIO="${MKBOOTIMG_STAGING_DIR}/vendor_ramdisk_binary.cpio"
    rm -f "${VENDOR_RAMDISK_CPIO}"
    for vendor_ramdisk_binary in ${VENDOR_RAMDISK_BINARY}; do
      if ! [ -f "${vendor_ramdisk_binary}" ]; then
        echo "Unable to locate vendor ramdisk ${vendor_ramdisk_binary}."
        exit 1
      fi
      if ${DECOMPRESS_GZIP} "${vendor_ramdisk_binary}" 2>/dev/null >> "${VENDOR_RAMDISK_CPIO}"; then
        echo "${vendor_ramdisk_binary} is GZIP compressed"
      elif ${DECOMPRESS_LZ4} "${vendor_ramdisk_binary}" 2>/dev/null >> "${VENDOR_RAMDISK_CPIO}"; then
        echo "${vendor_ramdisk_binary} is LZ4 compressed"
      elif cpio -t < "${vendor_ramdisk_binary}" &>/dev/null; then
        echo "${vendor_ramdisk_binary} is plain CPIO archive"
        cat "${vendor_ramdisk_binary}" >> "${VENDOR_RAMDISK_CPIO}"
      else
        echo "Unable to identify type of vendor ramdisk ${vendor_ramdisk_binary}"
        rm -f "${VENDOR_RAMDISK_CPIO}"
        exit 1
      fi
    done
    ( cd "${MKBOOTIMG_RAMDISK_STAGING_DIR}"
      cpio -idu --quiet <"${VENDOR_RAMDISK_CPIO}"
      rm -rf lib/modules
      eval ${VENDOR_RAMDISK_CMDS}
    )
  fi
  if [ -f "${VENDOR_FSTAB}" ]; then
    mkdir -p "${MKBOOTIMG_RAMDISK_STAGING_DIR}/first_stage_ramdisk"
    cp "${VENDOR_FSTAB}" "${MKBOOTIMG_RAMDISK_STAGING_DIR}/first_stage_ramdisk/"
  fi
  HAS_RAMDISK=
  MKBOOTIMG_RAMDISK_DIRS=()
  if [ -n "${VENDOR_RAMDISK_BINARY}" ] || [ -f "${VENDOR_FSTAB}" ]; then
    HAS_RAMDISK="1"
    MKBOOTIMG_RAMDISK_DIRS+=("${MKBOOTIMG_RAMDISK_STAGING_DIR}")
  fi
  if [ "${BUILD_INITRAMFS}" = "1" ]; then
    HAS_RAMDISK="1"
    if [ -z "${INITRAMFS_VENDOR_RAMDISK_FRAGMENT_NAME}" ]; then
      MKBOOTIMG_RAMDISK_DIRS+=("${INITRAMFS_STAGING_DIR}")
    fi
  fi
  if [ -z "${HAS_RAMDISK}" ] && [ -z "${SKIP_VENDOR_BOOT}" ]; then
    echo "No ramdisk found. Please provide a GKI and/or a vendor ramdisk."
    exit 1
  fi
  if [ "${#MKBOOTIMG_RAMDISK_DIRS[@]}" -gt 0 ]; then
    MKBOOTIMG_RAMDISK_CPIO="${MKBOOTIMG_STAGING_DIR}/ramdisk.cpio"
    mkbootfs "${MKBOOTIMG_RAMDISK_DIRS[@]}" >"${MKBOOTIMG_RAMDISK_CPIO}"
    ${RAMDISK_COMPRESS} "${MKBOOTIMG_RAMDISK_CPIO}" >"${DIST_DIR}/ramdisk.${RAMDISK_EXT}"
  fi
  if [ -n "${BUILD_BOOT_IMG}" ]; then
    if [ ! -f "${DIST_DIR}/$KERNEL_BINARY" ]; then
      echo "kernel binary(KERNEL_BINARY = $KERNEL_BINARY) not present in ${DIST_DIR}"
      exit 1
    fi
    MKBOOTIMG_ARGS+=("--kernel" "${DIST_DIR}/${KERNEL_BINARY}")
  fi
  if [ "${BOOT_IMAGE_HEADER_VERSION}" -ge "4" ]; then
    if [ -n "${VENDOR_BOOTCONFIG}" ]; then
      for PARAM in ${VENDOR_BOOTCONFIG}; do
        echo "${PARAM}"
      done >"${DIST_DIR}/vendor-bootconfig.img"
      MKBOOTIMG_ARGS+=("--vendor_bootconfig" "${DIST_DIR}/vendor-bootconfig.img")
      KERNEL_VENDOR_CMDLINE+=" bootconfig"
    fi
  fi
  if [ "${BOOT_IMAGE_HEADER_VERSION}" -ge "3" ]; then
    if [ -f "${GKI_RAMDISK_PREBUILT_BINARY}" ]; then
      MKBOOTIMG_ARGS+=("--ramdisk" "${GKI_RAMDISK_PREBUILT_BINARY}")
    fi
    if [ -z "${SKIP_VENDOR_BOOT}" ]; then
      MKBOOTIMG_ARGS+=("--vendor_boot" "${DIST_DIR}/vendor_boot.img")
      if [ -n "${KERNEL_VENDOR_CMDLINE}" ]; then
        MKBOOTIMG_ARGS+=("--vendor_cmdline" "${KERNEL_VENDOR_CMDLINE}")
      fi
      if [ -f "${DIST_DIR}/ramdisk.${RAMDISK_EXT}" ]; then
        MKBOOTIMG_ARGS+=("--vendor_ramdisk" "${DIST_DIR}/ramdisk.${RAMDISK_EXT}")
      fi
      if [ "${BUILD_INITRAMFS}" = "1" ] \
          && [ -n "${INITRAMFS_VENDOR_RAMDISK_FRAGMENT_NAME}" ]; then
        MKBOOTIMG_ARGS+=("--ramdisk_type" "DLKM")
        for MKBOOTIMG_ARG in ${INITRAMFS_VENDOR_RAMDISK_FRAGMENT_MKBOOTIMG_ARGS}; do
          MKBOOTIMG_ARGS+=("${MKBOOTIMG_ARG}")
        done
        MKBOOTIMG_ARGS+=("--ramdisk_name" "${INITRAMFS_VENDOR_RAMDISK_FRAGMENT_NAME}")
        MKBOOTIMG_ARGS+=("--vendor_ramdisk_fragment" "${DIST_DIR}/initramfs.img")
      fi
    fi
  else
    if [ -f "${DIST_DIR}/ramdisk.${RAMDISK_EXT}" ]; then
      MKBOOTIMG_ARGS+=("--ramdisk" "${DIST_DIR}/ramdisk.${RAMDISK_EXT}")
    fi
  fi
  if [ -n "${BUILD_BOOT_IMG}" ]; then
    MKBOOTIMG_ARGS+=("--output" "${DIST_DIR}/boot.img")
  fi
  for MKBOOTIMG_ARG in ${MKBOOTIMG_EXTRA_ARGS}; do
    MKBOOTIMG_ARGS+=("${MKBOOTIMG_ARG}")
  done
  "${MKBOOTIMG_PATH}" "${MKBOOTIMG_ARGS[@]}"
  if [ -n "${BUILD_BOOT_IMG}" -a -f "${DIST_DIR}/boot.img" ]; then
    echo "boot image created at ${DIST_DIR}/boot.img"
    if [ -n "${AVB_SIGN_BOOT_IMG}" ]; then
      if [ -n "${AVB_BOOT_PARTITION_SIZE}" ] \
          && [ -n "${AVB_BOOT_KEY}" ] \
          && [ -n "${AVB_BOOT_ALGORITHM}" ]; then
        echo "Signing the boot.img..."
        avbtool add_hash_footer --partition_name boot \
            --partition_size ${AVB_BOOT_PARTITION_SIZE} \
            --image ${DIST_DIR}/boot.img \
            --algorithm ${AVB_BOOT_ALGORITHM} \
            --key ${AVB_BOOT_KEY}
      else
        echo "Missing the AVB_* flags. Failed to sign the boot image" 1>&2
        exit 1
      fi
    fi
  fi
  [ -z "${SKIP_VENDOR_BOOT}" ] \
    && [ "${BOOT_IMAGE_HEADER_VERSION}" -ge "3" ] \
    && [ -f "${DIST_DIR}/vendor_boot.img" ] \
    && echo "vendor boot image created at ${DIST_DIR}/vendor_boot.img"
fi

if readelf -a ${DIST_DIR}/vmlinux 2>&1 | grep -q trace_printk_fmt; then
  echo "========================================================"
  echo "WARN: Found trace_printk usage in vmlinux."
  echo ""
  echo "trace_printk will cause trace_printk_init_buffers executed in kernel"
  echo "start, which will increase memory and lead warning shown during boot."
  echo "We should not carry trace_printk in production kernel."
  echo ""
  if [ ! -z "${STOP_SHIP_TRACEPRINTK}" ]; then
    echo "ERROR: stop ship on trace_printk usage." 1>&2
    exit 1
  fi
fi
