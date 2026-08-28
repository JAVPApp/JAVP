# Linux CMakeLists.txt — uses prebuilt lib if available, otherwise builds from source.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "libtorrent_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

# Map host arch (uname -m) to the prebuilt-zip slug used by GitHub Releases.
if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  set(LTF_LINUX_ARCH "arm64")
else()
  set(LTF_LINUX_ARCH "x64")
endif()

set(PREBUILT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../prebuilt/linux")
set(PREBUILT_SO "${PREBUILT_DIR}/${LTF_LINUX_ARCH}/liblibtorrent_flutter.so")

# Downloads land in the build tree rather than the package, matching Windows
# (where extracting through `.plugin_symlinks` is refused) and keeping fetched
# binaries out of the source checkout.
set(FETCH_DIR "${CMAKE_CURRENT_BINARY_DIR}/prebuilt")
set(FETCHED_SO "${FETCH_DIR}/${LTF_LINUX_ARCH}/liblibtorrent_flutter.so")

option(LIBTORRENT_FLUTTER_SKIP_DOWNLOAD "Skip downloading prebuilt native lib" OFF)

if(NOT EXISTS "${PREBUILT_SO}" AND NOT EXISTS "${FETCHED_SO}"
   AND NOT LIBTORRENT_FLUTTER_SKIP_DOWNLOAD)
  set(_PUBSPEC "${CMAKE_CURRENT_SOURCE_DIR}/../pubspec.yaml")
  if(EXISTS "${_PUBSPEC}")
    file(READ "${_PUBSPEC}" _PUBSPEC_CONTENT)
    if("${_PUBSPEC_CONTENT}" MATCHES "version:[ \t]*([^\r\n ]+)")
      set(_LTF_VERSION "${CMAKE_MATCH_1}")
      # This fork carries build metadata (1.9.2+javp.1); upstream release
      # tags are plain versions, so the suffix has to come off or every
      # download 404s and the build falls through to a source build that
      # needs vcpkg.
      string(REGEX REPLACE "\\+.*$" "" _LTF_VERSION "${_LTF_VERSION}")
      set(_DL_URL "https://github.com/ayman708-UX/libtorrent_flutter/releases/download/v${_LTF_VERSION}/linux-native-lib-${LTF_LINUX_ARCH}.zip")
      set(_ZIP "${CMAKE_CURRENT_BINARY_DIR}/linux-native-lib-${LTF_LINUX_ARCH}.zip")
      message(STATUS "libtorrent_flutter: downloading prebuilt from ${_DL_URL}")
      file(DOWNLOAD "${_DL_URL}" "${_ZIP}" SHOW_PROGRESS STATUS _DL_STATUS TLS_VERIFY ON)
      list(GET _DL_STATUS 0 _DL_CODE)
      if(_DL_CODE EQUAL 0)
        file(MAKE_DIRECTORY "${FETCH_DIR}")
        execute_process(
          COMMAND "${CMAKE_COMMAND}" -E tar xf "${_ZIP}"
          WORKING_DIRECTORY "${FETCH_DIR}"
          RESULT_VARIABLE _UNZIP_RC
        )
        file(REMOVE "${_ZIP}")
        if(NOT _UNZIP_RC EQUAL 0)
          message(WARNING "libtorrent_flutter: failed to extract prebuilt zip (rc=${_UNZIP_RC}); will build from source")
        endif()
        # Upstream zips used to nest under ${ARCH}/; newer ones are flat.
        if(NOT EXISTS "${FETCHED_SO}" AND EXISTS "${FETCH_DIR}/liblibtorrent_flutter.so")
          file(MAKE_DIRECTORY "${FETCH_DIR}/${LTF_LINUX_ARCH}")
          file(RENAME
            "${FETCH_DIR}/liblibtorrent_flutter.so"
            "${FETCH_DIR}/${LTF_LINUX_ARCH}/liblibtorrent_flutter.so")
        endif()
      else()
        message(WARNING "libtorrent_flutter: prebuilt download failed (${_DL_STATUS}); will build from source")
      endif()
    endif()
  endif()
endif()

if(EXISTS "${PREBUILT_SO}")
  message(STATUS "Using vendored Linux ${LTF_LINUX_ARCH} native library")
  set(libtorrent_flutter_bundled_libraries
    "${PREBUILT_SO}"
    PARENT_SCOPE
  )
elseif(EXISTS "${FETCHED_SO}")
  message(STATUS "Using downloaded Linux ${LTF_LINUX_ARCH} native library")
  set(libtorrent_flutter_bundled_libraries
    "${FETCHED_SO}"
    PARENT_SCOPE
  )
else()
  message(STATUS "Building from source (no prebuilt found at ${PREBUILT_SO})")
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")
  set(libtorrent_flutter_bundled_libraries
    $<TARGET_FILE:libtorrent_flutter>
    PARENT_SCOPE
  )
endif()