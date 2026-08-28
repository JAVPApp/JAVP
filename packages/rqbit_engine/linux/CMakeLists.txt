# Bundle the Rust cdylib. Flutter copies [rqbit_engine_bundled_libraries].
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "rqbit_engine")
project(${PROJECT_NAME} LANGUAGES CXX)

set(CRATE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../rust")
set(TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/rust-target")
set(_ARCH "x64")
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
  set(_ARCH "arm64")
endif()
set(PREBUILT "${CMAKE_CURRENT_SOURCE_DIR}/../prebuilt/linux/${_ARCH}/librqbit_engine.so")

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(CARGO_PROFILE "")
  set(CARGO_OUT_DIR "${TARGET_DIR}/debug")
else()
  set(CARGO_PROFILE "--release")
  set(CARGO_OUT_DIR "${TARGET_DIR}/release")
endif()
set(BUILT_SO "${CARGO_OUT_DIR}/librqbit_engine.so")

if(DEFINED ENV{RQBIT_ENGINE_SKIP_CARGO} AND EXISTS "${PREBUILT}")
  message(STATUS "rqbit_engine: using prebuilt ${PREBUILT}")
  set(rqbit_engine_bundled_libraries "${PREBUILT}" PARENT_SCOPE)
else()
  find_program(CARGO cargo)
  if(NOT CARGO)
    if(EXISTS "${PREBUILT}")
      message(STATUS "rqbit_engine: cargo missing; using prebuilt ${PREBUILT}")
      set(rqbit_engine_bundled_libraries "${PREBUILT}" PARENT_SCOPE)
    else()
      message(FATAL_ERROR
        "rqbit_engine: cargo not found and no prebuilt at ${PREBUILT}. "
        "Install rustup or set RQBIT_ENGINE_SKIP_CARGO=1 with a prebuilt .so.")
    endif()
  else()
    add_custom_target(rqbit_engine_rust ALL
      COMMAND "${CARGO}" build ${CARGO_PROFILE}
              --manifest-path "${CRATE_DIR}/Cargo.toml"
              --target-dir "${TARGET_DIR}"
      WORKING_DIRECTORY "${CRATE_DIR}"
      BYPRODUCTS "${BUILT_SO}"
      COMMENT "Building rqbit_engine (librqbit) with cargo"
      VERBATIM
    )
    set(rqbit_engine_bundled_libraries "${BUILT_SO}" PARENT_SCOPE)
  endif()
endif()
