#!/bin/bash
# H→ss̄ validation pipeline — self-contained, no /cefs or /hpcfs dependencies
# Image: cepc-darkshine.sif (MG5 3.6.7, Delphes CEPC_4th, GCC 11)
#
# Usage:
#   apptainer exec --fakeroot --writable-tmpfs cepc-darkshine.sif bash validate_hss.sh
#
# Environment:
#   HSS_WORKDIR   Working directory (default: /tmp/hss_validation)
#   HSS_NEVENTS   Number of events (default: 100)
#   HSS_BRANCH    Solver branch (default: release/dev/SII-build)
#
# Directory structure:
#   $HSS_WORKDIR/
#     source/     Cloned solver source
#     build/      CMake build
#     install/    make install
#     run/        Test jobs, output

set +e
WORK=${HSS_WORKDIR:-/tmp/hss_validation}
NEVENTS=${HSS_NEVENTS:-100}
BRANCH=${HSS_BRANCH:-release/dev/SII-build}
SOLVER_REPO="https://github.com/SII-inpac-Chuangqi/higgs-strange-solver.git"
MY_SM_REPO="https://github.com/SII-inpac-Chuangqi/benchmark-image.git"

rm -rf $WORK && mkdir -p $WORK/{source,build,install,run}
cd $WORK

source /opt/common/bin/thisroot.sh 2>/dev/null
source /opt/common/bin/geant4.sh 2>/dev/null || true
export PATH=/opt/mg5/bin:/opt/common/bin:$PATH
export LD_LIBRARY_PATH=/opt/common/lib:/opt/common/lib64:/opt/mg5/HEPTools/pythia8/lib:$LD_LIBRARY_PATH

PASS=0; FAIL=0
check() { local n=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  [PASS] $n"; ((PASS++))
    else echo "  [FAIL] $n"; ((FAIL++)); fi
}

echo "============================================"
echo " H->ss Validation Pipeline"
echo "============================================"

# ---- Part 1: Image checks ----
echo ""
echo "--- Image Checks ---"
check "ROOT 6.40"         root -l -q -e 'gROOT->GetVersion()' 2>&1 | grep -q "6.40"
check "Python 3.12"       python3.12 --version
check "GCC"               gcc --version
check "MG5_aMC 3.6.7"     [ -f /opt/mg5/bin/mg5_aMC ]
check "Pythia8"           [ -f /opt/mg5/HEPTools/pythia8/lib/libpythia8.so ]
check "HepMC3"            [ -x /opt/common/bin/HepMC3-config ]
check "LHAPDF"            which lhapdf-config
check "onnxruntime"       python3.12 -c "import onnxruntime" 2>/dev/null || { echo "  [INFO] Installing onnxruntime==1.16.3..."; pip3.12 install onnxruntime==1.16.3 2>&1 | tail -1; python3.12 -c "import onnxruntime"; }
check "DelphesHepMC2"     [ -x /opt/common/bin/DelphesHepMC2 ]
check "Delphes PCM"       [ -f /opt/common/lib/libClassesDict_rdict.pcm ]
check "CEPC 4th card"     [ -f /opt/common/cards/delphes_card_CEPC_4th.tcl ]
check "FeynGame"          [ -x /opt/common/bin/feyngame ]
check "numpy/ROOT"        python3.12 -c "import numpy, awkward, uproot, matplotlib, ROOT"

# ---- Part 2: Get my_sm model ----
echo ""
echo "--- Install my_sm model ---"
cd $WORK/source
# 1) Try bind-mounted benchmark-image (GFW workaround)
if [ -d /mnt/bi/models/my_sm ]; then
    cp -r /mnt/bi/models/my_sm /opt/mg5/models/ 2>/dev/null
    echo "  [OK] my_sm from /mnt/bi/models/my_sm"
# 2) Try git clone (works on Mac, fails inside container)
elif git clone --depth 1 "$MY_SM_REPO" bm 2>/dev/null && [ -d bm/models/my_sm ]; then
    cp -r bm/models/my_sm /opt/mg5/models/ 2>/dev/null
    rm -rf bm
    echo "  [OK] my_sm installed from GitHub"
# 3) Fallback: create minimal my_sm from sm (incomplete — missing vertices)
elif [ -f /opt/mg5/models/sm/parameters.py ]; then
    cp -r /opt/mg5/models/sm /opt/mg5/models/my_sm
    cat >> /opt/mg5/models/my_sm/parameters.py << 'PYADD'
yms = Parameter(name = 'yms', nature = 'external', type = 'real',
    value = 0.096, texname = '\\\\text{yms}',
    lhablock = 'YUKAWA', lhacode = [3])
PYADD
    echo "  [WARN] my_sm created from sm (minimal, may fail)"
else
    echo "  [FAIL] my_sm not available"
    ((FAIL++))
fi

# ---- Part 3: MG5 H->ss generation ----
echo ""
echo "--- MG5: e+e- -> ZH, Z -> vv, H -> ss ---"
cd $WORK/run

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
cd $WORK/run

HEPMC_GZ=$(find zh_hss/Events -name "tag_1_pythia8_events.hepmc*" 2>/dev/null | head -1)
if [ -n "$HEPMC_GZ" ]; then
    zcat "$HEPMC_GZ" > events.hepmc
    EVENTS=$(grep -c "^E " events.hepmc 2>/dev/null || echo 0)
    echo "  [PASS] MG5: $EVENTS events"
    ((PASS++))
else
    echo "  [FAIL] MG5: no output"
    ((FAIL++))
fi

# ---- Part 4: Delphes ----
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
    echo "  [SKIP] No HepMC"
fi

# ---- Part 5: Clone & Build Solver ----
echo ""
echo "--- Build higgs-strange-solver ---"
if [ -f hss_delphes.root ]; then
    cd $WORK/source
    CLONED=0
    # 1) Use pre-cloned copy from bind mount (GFW workaround)
    if [ -n "$HSS_SOLVER_SRC" ] && [ -f "$HSS_SOLVER_SRC/CMakeLists.txt" ]; then
        cp -r "$HSS_SOLVER_SRC" solver && CLONED=1
        echo "  [OK] Copied solver from HSS_SOLVER_SRC"
    elif [ -d /mnt/bi/solver_src ] && [ -f /mnt/bi/solver_src/CMakeLists.txt ]; then
        cp -r /mnt/bi/solver_src solver && CLONED=1
        echo "  [OK] Copied solver from /mnt/bi/solver_src"
    fi
    # 2) Try git clone (works on Mac, fails inside container behind GFW)
    if [ $CLONED -eq 0 ]; then
        if git clone -b "$BRANCH" "$SOLVER_REPO" solver 2>/dev/null; then
            CLONED=1
            echo "  [OK] Cloned solver ($BRANCH)"
        fi
    fi

    if [ $CLONED -eq 1 ]; then

        # Patch format strings for GCC 11
        for f in solver/util/inc/dataflow/event_loop.hpp \
                 solver/jet_split/inc/split_processor.hpp \
                 solver/event_merge/inc/merge_processor.hpp \
                 solver/sub_fusion/inc/fusion_processor.hpp; do
            [ -f "$f" ] && sed -i 's|{:.1f}|%.1f|g; s|{:04d}|%04d|g; s|{}_|%s_|g' "$f"
        done

        cat > solver/util/inc/util/format_compat.hpp << 'FMT'
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

        cd $WORK/build
        rm -rf * 2>/dev/null
        export DELPHES_DIR=/opt/common
        cmake $WORK/source/solver \
            -DCMAKE_INSTALL_PREFIX=$WORK/install \
            -DCMAKE_CXX_STANDARD=20 \
            -DCMAKE_CXX_FLAGS="-fconcepts" \
            -DCMAKE_PREFIX_PATH=/usr \
            -DDELPHES_INCLUDE_DIR=/opt/common/include \
            -DDELPHES_EXTERNALS_INCLUDE_DIR=/opt/common/include/external \
            > $WORK/build_cmake.log 2>&1
        echo "  cmake: $(tail -1 $WORK/build_cmake.log)"
        if make -j4 > $WORK/build_make.log 2>&1; then
            echo "  make: OK"
        else
            echo "  make: FAILED (see below)"
            tail -30 $WORK/build_make.log
        fi
        make install >> $WORK/build_make.log 2>&1 || true

        SPLIT=$(find $WORK/build $WORK/install -name split_jet -executable 2>/dev/null | head -1)
        MERGE=$(find $WORK/build $WORK/install -name merge_event -executable 2>/dev/null | head -1)

        if [ -n "$SPLIT" ] && [ -n "$MERGE" ]; then
            echo "  [PASS] Solver built"
            ((PASS++))

            cd $WORK/run
            cat > cfg_split.yaml << YAML
input: ["$WORK/run/hss_delphes.root"]
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

            cat > cfg_merge.yaml << YAML
input: ["$WORK/run/hss_delphes.root"]
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
    else
        echo "  [FAIL] Git clone failed (network?)"
        ((FAIL++))
    fi
else
    echo "  [SKIP] No Delphes"
fi

echo ""
echo "============================================"
echo " Results: $PASS passed, $FAIL failed"
echo " Workdir: $WORK"
echo "============================================"
exit $FAIL
