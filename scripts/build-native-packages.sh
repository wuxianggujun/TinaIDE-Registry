#!/usr/bin/env bash
# Build Android static packages for the Registry on a GitHub Actions runner.
# Usage: ./scripts/build-native-packages.sh [sqlite3] [zstd]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_ROOT="${WORK_ROOT:-${REGISTRY_ROOT}/.build/native-packages}"
OUTPUT_ROOT="${REGISTRY_ROOT}/packages"
ANDROID_API="${ANDROID_API:-28}"
SQLITE_VERSION="3.50.3"
SQLITE_NUMBER="3500300"
SQLITE_URL="https://www.sqlite.org/2025/sqlite-amalgamation-${SQLITE_NUMBER}.zip"
ZSTD_VERSION="1.5.7"
ZSTD_REPOSITORY="https://github.com/facebook/zstd.git"
ZSTD_REF="v${ZSTD_VERSION}"
ZSTD_COMMIT="ac66b19e6bd6b83238bf008eecc1298105298532"
ABIS=(arm64-v8a x86_64)

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    echo "ANDROID_NDK_HOME is required" >&2
    exit 1
fi
if [[ ! -f "${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" ]]; then
    echo "Android NDK toolchain not found under ${ANDROID_NDK_HOME}" >&2
    exit 1
fi

if [[ "$#" -eq 0 ]]; then
    PACKAGES=(sqlite3 zstd)
else
    PACKAGES=("$@")
fi
for package in "${PACKAGES[@]}"; do
    case "$package" in
        sqlite3|zstd) ;;
        *) echo "Unknown native package: $package" >&2; exit 1 ;;
    esac
done

TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
SOURCE_ROOT="${WORK_ROOT}/sources"
BUILD_ROOT="${WORK_ROOT}/build"
INSTALL_ROOT="${WORK_ROOT}/install"
STAGE_ROOT="${WORK_ROOT}/stage"
rm -rf "${WORK_ROOT}"
mkdir -p "${SOURCE_ROOT}" "${BUILD_ROOT}" "${INSTALL_ROOT}" "${STAGE_ROOT}"

log() { printf '[native-packages] %s\n' "$*"; }

setup_abi() {
    local abi="$1"
    case "$abi" in
        arm64-v8a)
            export CLANG_TARGET="aarch64-linux-android${ANDROID_API}"
            export CMAKE_ABI="arm64-v8a"
            ;;
        x86_64)
            export CLANG_TARGET="x86_64-linux-android${ANDROID_API}"
            export CMAKE_ABI="x86_64"
            ;;
        *) echo "Unsupported ABI: ${abi}" >&2; exit 1 ;;
    esac
    export CC="${TOOLCHAIN}/bin/${CLANG_TARGET}-clang"
    export CXX="${TOOLCHAIN}/bin/${CLANG_TARGET}-clang++"
    export AR="${TOOLCHAIN}/bin/llvm-ar"
    export CFLAGS="-O2 -fPIC"
    export CXXFLAGS="-O2 -fPIC"
}

download_sqlite() {
    local archive="${SOURCE_ROOT}/sqlite-amalgamation-${SQLITE_NUMBER}.zip"
    if [[ ! -f "${archive}" ]]; then
        log "Downloading SQLite ${SQLITE_VERSION}"
        curl --fail --location --retry 5 --retry-delay 2 --silent --show-error \
            --output "${archive}" "${SQLITE_URL}"
    fi
    local size="$(stat -c '%s' "${archive}")"
    if [[ "${size}" != "2845433" ]]; then
        echo "Unexpected SQLite archive size: ${size}" >&2
        exit 1
    fi
    if [[ ! -d "${SOURCE_ROOT}/sqlite-amalgamation-${SQLITE_NUMBER}" ]]; then
        unzip -q "${archive}" -d "${SOURCE_ROOT}"
    fi
}

checkout_zstd() {
    local source_dir="${SOURCE_ROOT}/zstd-${ZSTD_VERSION}"
    if [[ -d "${source_dir}/.git" ]]; then
        return
    fi
    log "Fetching zstd ${ZSTD_VERSION}"
    git init -q "${source_dir}"
    git -C "${source_dir}" remote add origin "${ZSTD_REPOSITORY}"
    git -C "${source_dir}" fetch --depth 1 origin "${ZSTD_REF}"
    git -C "${source_dir}" checkout --detach --force FETCH_HEAD
    local commit="$(git -C "${source_dir}" rev-parse HEAD)"
    if [[ "${commit}" != "${ZSTD_COMMIT}" ]]; then
        echo "Unexpected zstd commit: ${commit}" >&2
        exit 1
    fi
}

write_package_metadata() {
    local stage="$1"
    local id="$2"
    local name="$3"
    local version="$4"
    local homepage="$5"
    local license="$6"
    cat > "${stage}/package.json" <<EOF
{
  "id": "${id}",
  "name": "${name}",
  "version": "${version}",
  "packageRevision": 1,
  "platform": "android",
  "artifactType": "static",
  "installType": "download",
  "category": "library",
  "homepage": "${homepage}",
  "license": "${license}",
  "abis": ["arm64-v8a", "x86_64"],
  "files": { "include": "include", "lib": "lib", "cmake": "cmake", "pkgconfig": "pkgconfig" }
}
EOF
}

write_build_info() {
    local stage="$1"
    local id="$2"
    local version="$3"
    local upstream="$4"
    cat > "${stage}/BUILD-INFO.txt" <<EOF
package_id=${id}
package_version=${version}
package_revision=1
artifact_type=static
abis=arm64-v8a,x86_64
upstream=${upstream}
android_api=${ANDROID_API}
EOF
}

build_sqlite_for_abi() {
    local abi="$1"
    setup_abi "${abi}"
    download_sqlite
    local source_dir="${SOURCE_ROOT}/sqlite-amalgamation-${SQLITE_NUMBER}"
    local build_dir="${BUILD_ROOT}/sqlite3-${abi}"
    local stage_dir="${STAGE_ROOT}/sqlite3-${abi}"
    rm -rf "${build_dir}" "${stage_dir}"
    mkdir -p "${build_dir}" "${stage_dir}/include" "${stage_dir}/lib/${abi}" \
        "${stage_dir}/cmake" "${stage_dir}/pkgconfig"
    log "Building sqlite3 ${SQLITE_VERSION} for ${abi}"
    "${CC}" ${CFLAGS} \
        -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_MEMSTATUS=0 \
        -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE \
        -c "${source_dir}/sqlite3.c" -o "${build_dir}/sqlite3.o"
    "${AR}" rcs "${stage_dir}/lib/${abi}/libsqlite3.a" "${build_dir}/sqlite3.o"
    cp "${source_dir}/sqlite3.h" "${source_dir}/sqlite3ext.h" "${stage_dir}/include/"
    cat > "${stage_dir}/cmake/sqlite3Config.cmake" <<'EOF'
if(TARGET SQLite::SQLite3)
    return()
endif()
get_filename_component(_SQLITE3_PREFIX "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT ANDROID_ABI)
    set(ANDROID_ABI "arm64-v8a")
endif()
add_library(SQLite::SQLite3 STATIC IMPORTED)
set_target_properties(SQLite::SQLite3 PROPERTIES
    IMPORTED_LOCATION "${_SQLITE3_PREFIX}/lib/${ANDROID_ABI}/libsqlite3.a"
    INTERFACE_INCLUDE_DIRECTORIES "${_SQLITE3_PREFIX}/include"
)
EOF
    cat > "${stage_dir}/pkgconfig/sqlite3.pc" <<EOF
prefix=\${pcfiledir}/..
includedir=\${prefix}/include
libdir=\${prefix}/lib/${abi}

Name: sqlite3
Description: SQLite database engine
Version: ${SQLITE_VERSION}
Cflags: -I\${includedir}
Libs: -L\${libdir} -lsqlite3
EOF
    cat > "${stage_dir}/LICENSE.txt" <<'EOF'
SQLite is in the public domain. The SQLite source code is available from
https://www.sqlite.org/ and is not subject to any license restrictions.
EOF
    write_package_metadata "${stage_dir}" sqlite3 SQLite3 "${SQLITE_VERSION}" https://www.sqlite.org/ Public-Domain
    write_build_info "${stage_dir}" sqlite3 "${SQLITE_VERSION}" "sqlite-amalgamation-${SQLITE_NUMBER}"
}

build_zstd_for_abi() {
    local abi="$1"
    setup_abi "${abi}"
    checkout_zstd
    local source_dir="${SOURCE_ROOT}/zstd-${ZSTD_VERSION}"
    local build_dir="${BUILD_ROOT}/zstd-${abi}"
    local install_dir="${INSTALL_ROOT}/zstd-${abi}"
    local stage_dir="${STAGE_ROOT}/zstd-${abi}"
    rm -rf "${build_dir}" "${install_dir}" "${stage_dir}"
    mkdir -p "${stage_dir}/lib/${abi}" "${stage_dir}/cmake" "${stage_dir}/pkgconfig"
    log "Building zstd ${ZSTD_VERSION} for ${abi}"
    cmake -S "${source_dir}/build/cmake" -B "${build_dir}" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="${CMAKE_ABI}" -DANDROID_PLATFORM="android-${ANDROID_API}" \
        -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DZSTD_BUILD_PROGRAMS=OFF \
        -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_TESTS=OFF \
        -DCMAKE_INSTALL_PREFIX="${install_dir}" -DCMAKE_INSTALL_LIBDIR=lib
    cmake --build "${build_dir}" --parallel
    cmake --install "${build_dir}"
    cp -R "${install_dir}/include/." "${stage_dir}/include/"
    cp "${install_dir}/lib/libzstd.a" "${stage_dir}/lib/${abi}/"
    cat > "${stage_dir}/cmake/zstdConfig.cmake" <<'EOF'
if(TARGET zstd::libzstd_static)
    return()
endif()
get_filename_component(_ZSTD_PREFIX "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT ANDROID_ABI)
    set(ANDROID_ABI "arm64-v8a")
endif()
add_library(zstd::libzstd_static STATIC IMPORTED)
set_target_properties(zstd::libzstd_static PROPERTIES
    IMPORTED_LOCATION "${_ZSTD_PREFIX}/lib/${ANDROID_ABI}/libzstd.a"
    INTERFACE_INCLUDE_DIRECTORIES "${_ZSTD_PREFIX}/include"
)
if(NOT TARGET zstd::zstd)
    add_library(zstd::zstd INTERFACE IMPORTED)
    set_property(TARGET zstd::zstd PROPERTY INTERFACE_LINK_LIBRARIES zstd::libzstd_static)
endif()
EOF
    cat > "${stage_dir}/pkgconfig/zstd.pc" <<EOF
prefix=\${pcfiledir}/..
includedir=\${prefix}/include
libdir=\${prefix}/lib/${abi}

Name: zstd
Description: Zstandard compression library
Version: ${ZSTD_VERSION}
Cflags: -I\${includedir}
Libs: -L\${libdir} -lzstd
EOF
    cp "${source_dir}/LICENSE" "${stage_dir}/LICENSE.txt"
    write_package_metadata "${stage_dir}" zstd zstd "${ZSTD_VERSION}" https://github.com/facebook/zstd BSD-3-Clause
    write_build_info "${stage_dir}" zstd "${ZSTD_VERSION}" "${ZSTD_COMMIT}"
}

create_universal_archive() {
    local id="$1"
    local version="$2"
    local universal="${WORK_ROOT}/universal/${id}"
    local destination="${OUTPUT_ROOT}/${id}/${version}"
    rm -rf "${universal}"
    mkdir -p "${universal}/include" "${universal}/lib" "${universal}/cmake" "${universal}/pkgconfig"
    cp -R "${STAGE_ROOT}/${id}-arm64-v8a/include/." "${universal}/include/"
    cp -R "${STAGE_ROOT}/${id}-arm64-v8a/cmake/." "${universal}/cmake/"
    cp -R "${STAGE_ROOT}/${id}-arm64-v8a/pkgconfig/." "${universal}/pkgconfig/"
    cp "${STAGE_ROOT}/${id}-arm64-v8a/package.json" "${universal}/package.json"
    cp "${STAGE_ROOT}/${id}-arm64-v8a/LICENSE.txt" "${universal}/LICENSE.txt"
    cp "${STAGE_ROOT}/${id}-arm64-v8a/BUILD-INFO.txt" "${universal}/BUILD-INFO.txt"
    for abi in "${ABIS[@]}"; do
        mkdir -p "${universal}/lib/${abi}"
        cp -R "${STAGE_ROOT}/${id}-${abi}/lib/${abi}/." "${universal}/lib/${abi}/"
    done
    mkdir -p "${destination}"
    tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
        -C "${universal}" -cf - include lib cmake pkgconfig package.json LICENSE.txt BUILD-INFO.txt | \
        xz -9e --threads=0 > "${destination}/${id}.tar.xz"
}

for package in "${PACKAGES[@]}"; do
    case "${package}" in
        sqlite3)
            for abi in "${ABIS[@]}"; do build_sqlite_for_abi "${abi}"; done
            create_universal_archive sqlite3 "${SQLITE_VERSION}"
            ;;
        zstd)
            for abi in "${ABIS[@]}"; do build_zstd_for_abi "${abi}"; done
            create_universal_archive zstd "${ZSTD_VERSION}"
            ;;
    esac
done

log "Native package archives created under ${OUTPUT_ROOT}"
