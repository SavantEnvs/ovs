#!/usr/bin/env bash
#
# mayhem/build.sh — build Open vSwitch's six OSS-Fuzz harnesses (sanitized, libFuzzer + standalone) and
# the project's own test suite (normal flags). Re-runnable and offline: it fetches nothing.
#   fuzz tree: mayhem/build-fuzz   (ASan+UBSan, DWARF 3, SanCov on the library)
#   test tree: mayhem/build-test   (project's normal flags; test.sh runs the suite from here)
# Both are out-of-tree builds; mayhem/.gitignore covers them so `git clean -ffdX` removes them.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
# Same UBSan set OSS-Fuzz uses for this project: everything except `alignment`. OVS reads protocol
# structs straight out of byte streams (ofp_print walks back-to-back messages at arbitrary offsets), which
# is benign on the supported targets and would otherwise halt ofp_print_target on its first input.
FUZZ_SAN="$SANITIZER_FLAGS -fno-sanitize=alignment"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

TARGETS=(flow_extract_target json_parser_target ofp_print_target odp_target miniflow_target ofctl_parse_target)
CONFIGURE_ARGS=(--disable-ssl --disable-libcapng --disable-shared)
# ALL_LOCAL= skips upstream's git-tree hygiene checks (dist-hook-git: every tracked file must be in the
# dist tarball), which would reject this additive mayhem/ layer.
MAKE=(make -j"$MAYHEM_JOBS" ALL_LOCAL=)

[ -x configure ] || ./boot.sh

# 1) Sanitized fuzz tree. fuzzer-no-link puts SanCov in the library so Mayhem sees coverage.
mkdir -p mayhem/build-fuzz
(
  cd mayhem/build-fuzz
  [ -f Makefile ] || "$SRC/configure" CC="$CC" \
      CFLAGS="$FUZZ_SAN $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link" "${CONFIGURE_ARGS[@]}"
  "${MAKE[@]}" all
)

# LeakSanitizer off at build time, linked into every fuzz and standalone binary.
LSAN_OBJ="$SRC/mayhem/build-fuzz/lsan_off.o"
$CXX $FUZZ_SAN $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_OBJ"
# The driver is C: compile it as C so its LLVMFuzzerTestOneInput reference keeps C linkage.
STANDALONE_OBJ="$SRC/mayhem/build-fuzz/standalone_main.o"
$CC $FUZZ_SAN $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$STANDALONE_OBJ"

link_targets() {  # <ldflags> <suffix>
  local ldflags="$1" suffix="$2" t
  local vars=()
  for t in "${TARGETS[@]}"; do
    rm -f "mayhem/build-fuzz/tests/oss-fuzz/$t"
    vars+=("tests_oss_fuzz_${t}_LDFLAGS=$ldflags")
  done
  (cd mayhem/build-fuzz && "${MAKE[@]}" "${vars[@]}" \
      $(printf 'tests/oss-fuzz/%s ' "${TARGETS[@]}"))
  for t in "${TARGETS[@]}"; do
    cp "mayhem/build-fuzz/tests/oss-fuzz/$t" "$SRC/$t$suffix"
  done
}

link_targets "$FUZZ_SAN $DEBUG_FLAGS $LIB_FUZZING_ENGINE $LSAN_OBJ" ""
link_targets "$FUZZ_SAN $DEBUG_FLAGS $STANDALONE_OBJ $LSAN_OBJ" "-standalone"

# 2) Test tree with the project's normal flags. `check` with -l builds everything the suite needs
#    (ovstest, daemons, the generated testsuite script) without running it.
mkdir -p mayhem/build-test
(
  cd mayhem/build-test
  [ -f Makefile ] || env -u CFLAGS -u LDFLAGS "$SRC/configure" CC="$CC" \
      CFLAGS="-g -O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" "${CONFIGURE_ARGS[@]}"
  "${MAKE[@]}" all
  "${MAKE[@]}" check TESTSUITEFLAGS=-l
)
