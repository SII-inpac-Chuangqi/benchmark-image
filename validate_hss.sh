#!/bin/bash
# Unified H→ss̄ validation pipeline: validate + MG5 → Delphes → Solver
# Image: cepc-darkshine.sif (MG5 3.6.7, Delphes CEPC_4th)
# Usage:
#   apptainer exec --fakeroot --writable-tmpfs --bind /cefs:/cefs \
#       cepc-darkshine.sif bash validate_hss.sh
#
# Solver: cloned from GitHub SII-inpac-Chuangqi/higgs-strange-solver
#         (release/dev/SII-build), falls back to CEFS patched copy
# MG5 model: my_sm (from Jiang, includes strange Yukawa yms=0.096)
# Output: ${HSS_OUT:-/tmp/hss_validation}/

set +e
OUT=${HSS_OUT:-/tmp/hss_validation}
rm -rf $OUT && mkdir -p $OUT && cd $OUT

source /opt/common/bin/thisroot.sh 2>/dev/null
source /opt/common/bin/geant4.sh 2>/dev/null || true
export PATH=/opt/mg5/bin:/opt/common/bin:$PATH
export LD_LIBRARY_PATH=/opt/common/lib:/opt/common/lib64:/opt/mg5/HEPTools/pythia8/lib:$LD_LIBRARY_PATH

PASS=0; FAIL=0
check() {
    local n=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  [PASS] $n"; ((PASS++))
    else echo "  [FAIL] $n"; ((FAIL++)); fi
}

echo "============================================"
echo " H->ss Validation: Image Checks + Pipeline"
echo "============================================"

# ---- Part 1: Software Availability ----
echo ""
echo "--- Software Checks ---"
check "ROOT 6.40"         root -l -q -e 'gROOT->GetVersion()' 2>&1 | grep -q "6.40"
check "Python 3.12"       python3.12 --version
check "GCC"               gcc --version
check "MG5_aMC 3.6.7"     [ -f /opt/mg5/bin/mg5_aMC ]
check "Pythia8 lib"       [ -f /opt/mg5/HEPTools/pythia8/lib/libpythia8.so ]
check "HepMC3"            [ -x /opt/common/bin/HepMC3-config ]
check "LHAPDF"            which lhapdf-config
check "onnxruntime"       python3.12 -c "import onnxruntime"
check "DelphesHepMC2"     [ -x /opt/common/bin/DelphesHepMC2 ]
check "Delphes PCM"       [ -f /opt/common/lib/libClassesDict_rdict.pcm ]
check "CEPC 4th card"     [ -f /opt/common/cards/delphes_card_CEPC_4th.tcl ]
check "FeynGame"          [ -x /opt/common/bin/feyngame ]
check "numpy/awkward"     python3.12 -c "import numpy, awkward, uproot, matplotlib, ROOT"

# ---- Part 2: Install my_sm model ----
echo ""
echo "--- Install my_sm model (strange Yukawa) ---"
MY_SM_SRC="${MY_SM_SRC:-/cefs/higgs/zhuyifan/DarkSHINE/darkshine-build/my_sm}"
if [ -d "$MY_SM_SRC" ]; then
    cp -r "$MY_SM_SRC" /opt/mg5/models/ 2>/dev/null && echo "  [OK] my_sm installed" || echo "  [WARN] my_sm copy failed"
else
    echo "  [WARN] my_sm not found at $MY_SM_SRC — will try heft fallback"
fi

# ---- Part 3: MG5 Event Generation ----
echo ""
echo "--- MG5: e+e- -> ZH, Z -> vv, H -> ss ---"
NEVENTS=${HSS_NEVENTS:-100}

cat > hss_mg5.txt << 'MGEOF'
import model my_sm
define vl = ve vm vt
define vl~ = ve~ vm~ vt~
generate e+ e- > z h, z > vl vl~, h > s s~
output zh_hss
exit
MGEOF
mg5_aMC hss_mg5.txt 2>&1 | tail -3

cat > zh_hss/madevent.macro << MACRO
launch
shower=Pythia8
set nevents ${NEVENTS}
set iseed 42
set lpp1 -3
set lpp2 +3
set ebeam1 120
set ebeam2 120
set pdlabel isronlyll
0
exit
MACRO

echo "  Generating ${NEVENTS} events..."
cd zh_hss && bin/madevent madevent.macro 2>&1 | tail -5
cd $OUT

HEPMC_GZ=$(find zh_hss/Events -name "tag_1_pythia8_events.hepmc*" 2>/dev/null | head -1)
if [ -n "$HEPMC_GZ" ]; then
    zcat "$HEPMC_GZ" > events.hepmc
    EVENTS=$(grep -c "^E " events.hepmc 2>/dev/null || echo 0)
    echo "  [PASS] MG5: $EVENTS events (my_sm, H->ss)"
    ((PASS++))
else
    echo "  [FAIL] MG5: no HepMC output"
    ((FAIL++))
fi

# ---- Part 4: Delphes Fast Simulation ----
echo ""
echo "--- Delphes CEPC_4th ---"
if [ -f events.hepmc ]; then
    DelphesHepMC2 /opt/common/cards/delphes_card_CEPC_4th.tcl hss_delphes.root events.hepmc 2>&1 | tail -3
    if [ -f hss_delphes.root ]; then
        echo "  [PASS] Delphes: $(stat -c%s hss_delphes.root 2>/dev/null || echo ok) bytes"
        ((PASS++))
    else
        echo "  [FAIL] Delphes"
        ((FAIL++))
    fi
else
    echo "  [SKIP] No HepMC input"
fi

# ---- Part 5: Clone & Build Solver ----
echo ""
echo "--- Build higgs-strange-solver ---"
if [ -f hss_delphes.root ]; then
    SOLVER_SRC=""
    # Try GitHub first, fallback to CEFS patched copy
    SOLVER_REPO="https://github.com/SII-inpac-Chuangqi/higgs-strange-solver.git"
    SOLVER_BRANCH="${HSS_BRANCH:-release/dev/SII-build}"
    CEFS_SRC="/cefs/higgs/zhuyifan/DarkSHINE/darkshine-build/hss_zh/solver_src"

    if git clone -b "$SOLVER_BRANCH" "$SOLVER_REPO" solver_src_git 2>/dev/null; then
        SOLVER_SRC="$OUT/solver_src_git"
        echo "  [OK] Cloned from GitHub"
        # Patch format strings for GCC 11
        for f in "$SOLVER_SRC/util/inc/dataflow/event_loop.hpp" \
                 "$SOLVER_SRC/jet_split/inc/split_processor.hpp" \
                 "$SOLVER_SRC/event_merge/inc/merge_processor.hpp" \
                 "$SOLVER_SRC/sub_fusion/inc/fusion_processor.hpp"; do
            [ -f "$f" ] && sed -i 's|{:.1f}|%.1f|g; s|{:04d}|%04d|g; s|{}_|%s_|g; s|{}|%s|g' "$f"
        done
        # Ensure format_compat.hpp has to_cstr for std::string
        cat > "$SOLVER_SRC/util/inc/util/format_compat.hpp" << 'FMT'
#pragma once
#include <cstdio>
#include <string>
namespace hss {
inline const char* to_cstr(const std::string& s){return s.c_str();}
inline const char* to_cstr(const char* s){return s;}
inline int to_cstr(int v){return v;}
inline double to_cstr(double v){return v;}
inline float to_cstr(float v){return v;}
template<typename...A> std::string format(const char* f,A...a){
  char b[512];snprintf(b,sizeof(b),f,to_cstr(a)...);return std::string(b);}
}
FMT
    elif [ -d "$CEFS_SRC" ]; then
        SOLVER_SRC="$CEFS_SRC"
        echo "  [OK] Using CEFS patched copy"
    else
        echo "  [FAIL] No solver source available"
        ((FAIL++))
    fi

    if [ -n "$SOLVER_SRC" ]; then
        SOLVER_BUILD=$OUT/solver_build
        rm -rf $SOLVER_BUILD && mkdir -p $SOLVER_BUILD && cd $SOLVER_BUILD
        export DELPHES_DIR=/opt/common
        cmake $SOLVER_SRC \
            -DCMAKE_CXX_STANDARD=20 \
            -DCMAKE_CXX_FLAGS="-fconcepts" \
            -DCMAKE_PREFIX_PATH=/usr \
            -DDELPHES_INCLUDE_DIR=/opt/common/include \
            -DDELPHES_EXTERNALS_INCLUDE_DIR=/opt/common/include/external \
            2>&1 | tail -2
        make -j4 2>&1 | tail -5

        SPLIT=$(find $SOLVER_BUILD -name split_jet -executable 2>/dev/null | head -1)
        MERGE=$(find $SOLVER_BUILD -name merge_event -executable 2>/dev/null | head -1)

        if [ -n "$SPLIT" ] && [ -n "$MERGE" ]; then
            echo "  [PASS] Solver built"
            ((PASS++))

            # ---- jet_split ----
            cd $OUT
            cat > cfg_split.yaml << YAML
input: ["$OUT/hss_delphes.root"]
max_entries: ${NEVENTS}
entries_per_output: ${NEVENTS}
output_path: "split_out"
channel: "ss"
parent_particle: "Higgs"
generator: "madgraph"
YAML
            rm -rf split_out && mkdir split_out
            $SPLIT -c cfg_split.yaml 2>&1 | grep Creating
            [ -f split_out/split_ss_0000.root ] && echo "  [PASS] jet_split" && ((PASS++)) || { echo "  [FAIL] jet_split"; ((FAIL++)); }

            # ---- event_merge ----
            cat > cfg_merge.yaml << YAML
input: ["$OUT/hss_delphes.root"]
max_entries: ${NEVENTS}
entries_per_output: ${NEVENTS}
output_path: "merge_out"
channel: "ss"
generator: "madgraph"
YAML
            rm -rf merge_out && mkdir merge_out
            $MERGE -c cfg_merge.yaml 2>&1 | grep Creating
            [ -f merge_out/merge_ss_0000.root ] && echo "  [PASS] event_merge" && ((PASS++)) || { echo "  [FAIL] event_merge"; ((FAIL++)); }
        else
            echo "  [FAIL] Solver build"
            ((FAIL++))
        fi
    fi
else
    echo "  [SKIP] No Delphes output"
fi

echo ""
echo "============================================"
echo " Results: $PASS passed, $FAIL failed"
echo " Output: $OUT"
echo "============================================"
exit $FAIL
