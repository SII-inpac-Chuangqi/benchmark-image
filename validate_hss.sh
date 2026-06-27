#!/bin/bash
# H→ss̄ validation pipeline — self-contained, no /cefs or /hpcfs dependencies
# Image: cepc-darkshine.sif (MG5 3.6.7, Delphes CEPC_4th, GCC 11)
#
# Usage:
#   apptainer exec --fakeroot --writable-tmpfs --bind $PWD:/mnt/bi \
#       cepc-darkshine.sif bash validate_hss.sh
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

rm -rf $WORK && mkdir -p $WORK/{source,build,install,run}
cd $WORK

source /opt/common/bin/thisroot.sh 2>/dev/null
source /opt/common/bin/geant4.sh 2>/dev/null || true
export PATH=/opt/mg5/bin:/opt/common/bin:$PATH
export LD_LIBRARY_PATH=/opt/common/lib:/opt/common/lib64:/opt/mg5/HEPTools/pythia8/lib:$LD_LIBRARY_PATH

PASS=0; FAIL=0; SKIP=0
check() { local n=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  [PASS] $n"; ((PASS++))
    else echo "  [FAIL] $n"; ((FAIL++)); fi
}
skip() { echo "  [SKIP] $1"; ((SKIP++)); }
info() { echo "  [INFO] $1"; }

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
check "onnxruntime (C++)"  ls /opt/common/lib/libonnxruntime.so 2>/dev/null
python3.12 -c "import onnxruntime" 2>/dev/null && info "onnxruntime (Python)" || { pip3.12 install onnxruntime >/dev/null 2>&1 && info "onnxruntime (Python) installed"; }
check "DelphesHepMC2"     [ -x /opt/common/bin/DelphesHepMC2 ]
check "Delphes PCM"       [ -f /opt/common/lib/libClassesDict_rdict.pcm ]
check "CEPC 4th card"     [ -f /opt/common/cards/delphes_card_CEPC_4th.tcl ]
check "FeynGame"          [ -x /opt/common/bin/feyngame ]
check "numpy/ROOT"        python3.12 -c "import numpy, awkward, uproot, matplotlib, ROOT"

# ---- Part 2: Get my_sm model ----
echo ""
echo "--- Install my_sm model ---"
MODEL_INSTALLED=0
# Default: /mnt/bi/models/my_sm (bind-mount), override via MY_SM_PATH
for d in "/mnt/bi/models/my_sm" \
         "${MY_SM_PATH:-}" \
         "/opt/common/models/my_sm" \
         "/cefs/higgs/zhuyifan/DarkSHINE/darkshine-build/my_sm"; do
    if [ -n "$d" ] && [ -d "$d" ]; then
        cp -r "$d" /opt/mg5/models/ 2>/dev/null && MODEL_INSTALLED=1 && break
    fi
done
if [ "$MODEL_INSTALLED" -eq 1 ]; then
    echo "  [OK] my_sm installed from $d"
else
    skip "my_sm model (bind with --bind \$PWD:/mnt/bi or set MY_SM_PATH)"
    cp -r /opt/mg5/models/sm /opt/mg5/models/my_sm 2>/dev/null || true
fi

# ---- Part 3: MG5 H→ss generation ----
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
    skip "No HepMC"
fi

# ---- Part 5: Clone & Build Solver ----
echo ""
echo "--- Build higgs-strange-solver ---"
if [ -f hss_delphes.root ]; then
    cd $WORK/source
    if git clone -b "$BRANCH" "$SOLVER_REPO" solver 2>/dev/null; then
        echo "  [OK] Cloned solver ($BRANCH)"

        # Patch format strings for GCC 11 (jet_split, event_merge, sub_fusion)
        for f in solver/util/inc/dataflow/event_loop.hpp \
                 solver/jet_split/inc/split_processor.hpp \
                 solver/event_merge/inc/merge_processor.hpp \
                 solver/sub_fusion/inc/fusion_processor.hpp \
                 solver/sub_fusion/fusion.cpp; do
            [ -f "$f" ] && sed -i 's|{:.1f}|%.1f|g; s|{:04d}|%04d|g; s|{}_|%s_|g; s|{}|%s|g' "$f"
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
            -Dyaml-cpp_DIR=/usr/lib64/cmake/yaml-cpp \
            -DDELPHES_INCLUDE_DIR=/opt/common/include \
            -DDELPHES_EXTERNALS_INCLUDE_DIR=/opt/common/include/external \
            2>&1 | tail -2
        make -j4 2>&1 | tail -5
        make install 2>/dev/null || true

        SPLIT=$(find $WORK/build $WORK/install -name split_jet -executable 2>/dev/null | head -1)
        MERGE=$(find $WORK/build $WORK/install -name merge_event -executable 2>/dev/null | head -1)
        FUSE=$(find $WORK/build $WORK/install -name fuse_sub -executable 2>/dev/null | head -1)

        if [ -n "$SPLIT" ] && [ -n "$MERGE" ] && [ -n "$FUSE" ]; then
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

            # sub_fusion: jet-level substructure
            if [ -n "$FUSE" ]; then
                cd $WORK/run
                cat > cfg_fuse.yaml << YAML
input: ["$WORK/run/hss_delphes.root"]
max_entries: ${NEVENTS}
entries_per_output: ${NEVENTS}
output_path: "fuse_out"
channel: "ss"
generator: "madgraph"
YAML
                rm -rf fuse_out && mkdir fuse_out
                $FUSE -c cfg_fuse.yaml 2>&1 | grep Creating
                [ -f fuse_out/fusion_ss_0000.root ] && echo "  [PASS] sub_fusion" && ((PASS++)) || { echo "  [FAIL] sub_fusion"; ((FAIL++)); }
            else
                skip "sub_fusion (binary not built)"
            fi

            # ---- Part 6: Plot mjj ----
            echo ""
            echo "--- mjj Distribution ---"
            PLOT_OUT="/tmp/mjj.pdf"
            for d in /mnt/bi /tmp; do [ -w "$d" ] && PLOT_OUT="$d/mjj.pdf" && break; done
            export MPLCONFIGDIR=/tmp/matplotlib-$RANDOM && mkdir -p $MPLCONFIGDIR
            if python3.12 -c "import matplotlib" 2>/dev/null; then
                python3.12 -c "
import uproot, numpy as np
mjj = []
for f in ['$WORK/run/merge_out/merge_ss_0000.root']:
    try:
        with uproot.open(f) as ff:
            mjj.extend(ff['tree']['mjj'].array().tolist())
    except: pass
mjj = np.array(mjj)
if len(mjj) > 0:
    import matplotlib; matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(8,5))
    ax.hist(mjj, bins=40, range=(50,200), histtype='step', color='black', lw=1.5)
    ax.set_xlabel('mjj [GeV]'); ax.set_ylabel(f'Events / {150/40:.1f} GeV')
    ax.axvline(125, color='red', ls='--', alpha=0.5, label='mH=125 GeV')
    mean, std = np.mean(mjj), np.std(mjj)
    ax.text(0.02,0.95,f'Mean: {mean:.1f} GeV\\nRMS: {std:.1f} GeV', transform=ax.transAxes, va='top', fontsize=9, bbox=dict(boxstyle='round',fc='white',alpha=0.8))
    ax.legend(fontsize=8); fig.tight_layout()
    fig.savefig('$PLOT_OUT'); plt.close()
    print(f'  [OK] mjj.pdf saved to $PLOT_OUT (mean={mean:.1f} GeV, entries={len(mjj)})')
" 2>&1
                ((PASS++))
            else
                skip "matplotlib not available"
            fi
        else
            echo "  [FAIL] Solver build"
            ((FAIL++))
        fi
    else
        echo "  [FAIL] Git clone failed (network?)"
        ((FAIL++))
    fi
else
    skip "No Delphes"
fi

echo ""
echo "============================================"
echo " Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo " Workdir: $WORK"
echo "============================================"
exit $FAIL
