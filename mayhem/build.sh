#!/usr/bin/env bash
#
# mayhem/build.sh — build the LLDP receive harness (sanitized, libFuzzer + standalone) and
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
# structs straight out of byte streams at arbitrary offsets, which is benign on the supported targets.
FUZZ_SAN="$SANITIZER_FLAGS -fno-sanitize=alignment"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

TARGET=lldp_recv_target
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

# The harness is not part of upstream's automake build (the layer stays inside mayhem/): compile it
# with the library's own include paths and link it through libtool against the sanitized library.
HARNESS_OBJ="$SRC/mayhem/build-fuzz/$TARGET.o"
$CC $FUZZ_SAN $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link -DHAVE_CONFIG_H \
    -I"$SRC/mayhem/build-fuzz" -I"$SRC/include" -I"$SRC/mayhem/build-fuzz/include" \
    -I"$SRC/lib" -I"$SRC/mayhem/build-fuzz/lib" \
    -c "$SRC/mayhem/$TARGET.c" -o "$HARNESS_OBJ"

link_target() {  # <ldflags> <output>
  (cd mayhem/build-fuzz && ./libtool --quiet --tag=CC --mode=link "$CC" $1 "$HARNESS_OBJ" \
      lib/libopenvswitch.la -o "$2")
}

link_target "$FUZZ_SAN $DEBUG_FLAGS $LIB_FUZZING_ENGINE $LSAN_OBJ" "$SRC/$TARGET"
link_target "$FUZZ_SAN $DEBUG_FLAGS $STANDALONE_OBJ $LSAN_OBJ" "$SRC/$TARGET-standalone"

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
