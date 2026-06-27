#!/bin/bash
# Full H→ss̄ pipeline: MG5 → Delphes → higgs-strange-solver (jet_split + event_merge)
# Image: cepc-darkshine.sif (MG5 3.6.7, Delphes with CEPC_4th card)
# Usage:
#   apptainer exec --fakeroot --bind /cefs:/cefs \
#       cepc-darkshine.sif bash hss_pipeline.sh
#
# Solver: cloned from GitHub SII-inpac-Chuangqi/higgs-strange-solver (dev/SII-build)
# Output: /tmp/hss_pipeline_out/ (set HSS_OUT for persistence)

set +e

OUT=${HSS_OUT:-/tmp/hss_pipeline_out}
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
echo " H→ss̄ Full Pipeline: MG5 → Delphes → Solver"
echo "============================================"
echo ""

# ---- Step 1: MG5 Event Generation ----
echo "--- Step 1: MG5 event generation (e+e- → Z → ss̄) ---"
cat > hss_mg5.txt << 'MGEOF'
import model sm
generate e+ e- > z, z > s s~
output hss_prod
exit
MGEOF
mg5_aMC hss_mg5.txt 2>&1 | tail -3

cat > hss_prod/madevent.macro << 'MACRO'
launch
shower=Pythia8
set nevents 100
set iseed 42
set lpp1 -3
set lpp2 +3
set ebeam1 120
set ebeam2 120
set pdlabel isronlyll
0
exit
MACRO

echo "  Generating 100 events with Pythia8 shower..."
cd hss_prod && bin/madevent madevent.macro 2>&1 | tail -5
cd $OUT

HEPMC_GZ=$(find hss_prod/Events -name "tag_1_pythia8_events.hepmc*" 2>/dev/null | head -1)
if [ -n "$HEPMC_GZ" ]; then
    if [[ "$HEPMC_GZ" == *.gz ]]; then
        zcat "$HEPMC_GZ" > events.hepmc
    else
        cp "$HEPMC_GZ" events.hepmc
    fi
    EVENTS=$(grep -c "^E " events.hepmc 2>/dev/null || echo 0)
    echo "  [PASS] MG5: $EVENTS events generated"
    ((PASS++))
else
    echo "  [FAIL] MG5: no HepMC output"
    ((FAIL++))
fi

# ---- Step 2: Delphes Fast Simulation ----
echo ""
echo "--- Step 2: Delphes (CEPC_4th card) ---"
if [ -f events.hepmc ]; then
    DelphesHepMC2 /opt/common/cards/delphes_card_CEPC_4th.tcl hss_delphes.root events.hepmc 2>&1 | grep -c "initializing" >/dev/null
    if [ -f hss_delphes.root ]; then
        SIZE=$(stat -c%s hss_delphes.root 2>/dev/null || stat -f%z hss_delphes.root 2>/dev/null)
        echo "  [PASS] Delphes: hss_delphes.root ($SIZE bytes)"
        ((PASS++))
    else
        echo "  [FAIL] Delphes: no output"
        ((FAIL++))
    fi
else
    echo "  [SKIP] No HepMC input"
fi

# ---- Step 3: Clone & Build Solver from GitHub ----
echo ""
echo "--- Step 3: Clone & Build higgs-strange-solver ---"
if [ -f hss_delphes.root ]; then
    SOLVER_REPO="https://github.com/SII-inpac-Chuangqi/higgs-strange-solver.git"
    SOLVER_BRANCH="${HSS_BRANCH:-dev/SII-build}"
    SOLVER_SRC=$OUT/solver_src
    SOLVER_BUILD=$OUT/solver_build

    echo "  Cloning $SOLVER_REPO ($SOLVER_BRANCH)..."
    git clone -b "$SOLVER_BRANCH" "$SOLVER_REPO" "$SOLVER_SRC" 2>&1 | tail -2

    # Ensure Findonnxruntime.cmake exists
    if [ ! -f "$SOLVER_SRC/cmake/Findonnxruntime.cmake" ]; then
        cat > "$SOLVER_SRC/cmake/Findonnxruntime.cmake" << 'CMAKE'
find_path(onnxruntime_INCLUDE_DIR onnxruntime_c_api.h
    PATHS /opt/common/include/onnxruntime
    PATH_SUFFIXES core/session
    NO_DEFAULT_PATH)
find_library(onnxruntime_LIBRARY onnxruntime
    PATHS /opt/common/lib
    NO_DEFAULT_PATH)
include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(onnxruntime
    REQUIRED_VARS onnxruntime_LIBRARY onnxruntime_INCLUDE_DIR)
if(onnxruntime_FOUND AND NOT TARGET onnxruntime::onnxruntime)
    add_library(onnxruntime::onnxruntime SHARED IMPORTED)
    set_target_properties(onnxruntime::onnxruntime PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "${onnxruntime_INCLUDE_DIR}"
        IMPORTED_LOCATION "${onnxruntime_LIBRARY}")
endif()
CMAKE
    fi

    rm -rf $SOLVER_BUILD && mkdir -p $SOLVER_BUILD && cd $SOLVER_BUILD
    export DELPHES_DIR=/opt/common
    cmake $SOLVER_SRC \
        -DCMAKE_CXX_STANDARD=20 \
        -DCMAKE_CXX_FLAGS="-fconcepts" \
        -DDELPHES_INCLUDE_DIR=/opt/common/include \
        -DDELPHES_EXTERNALS_INCLUDE_DIR=/opt/common/include/external \
        2>&1 | tail -3
    make -j4 2>&1 | tail -5

    SPLIT_BIN=$(find . -name split_jet -type f -executable 2>/dev/null | head -1)
    MERGE_BIN=$(find . -name merge_event -type f -executable 2>/dev/null | head -1)

    if [ -n "$SPLIT_BIN" ] && [ -n "$MERGE_BIN" ]; then
        echo "  [PASS] Solver built: split_jet + merge_event"
        ((PASS++))

        # ---- Step 4: jet_split ----
        echo ""
        echo "--- Step 4: jet_split ---"
        cat > $OUT/config_split.yaml << YAML
input: ["$OUT/hss_delphes.root"]
max_entries: 100
entries_per_output: 100
output_path: "split_out"
channel: "ss"
parent_particle: "Higgs"
generator: "madgraph"
YAML
        cd $OUT
        rm -rf split_out && mkdir split_out
        $SPLIT_BIN -c config_split.yaml 2>&1 | tail -3
        if [ -f split_out/split_ss_0000.root ]; then
            echo "  [PASS] jet_split: split_ss_0000.root"
            ((PASS++))
        else
            echo "  [FAIL] jet_split: no output"
            ((FAIL++))
        fi

        # ---- Step 5: event_merge ----
        echo ""
        echo "--- Step 5: event_merge ---"
        cat > $OUT/config_merge.yaml << YAML
input: ["$OUT/hss_delphes.root"]
max_entries: 100
entries_per_output: 100
output_path: "merge_out"
channel: "ss"
generator: "madgraph"
YAML
        rm -rf merge_out && mkdir merge_out
        $MERGE_BIN -c config_merge.yaml 2>&1 | tail -3
        if [ -f merge_out/merge_ss_0000.root ]; then
            echo "  [PASS] event_merge: merge_ss_0000.root"
            ((PASS++))
        else
            echo "  [FAIL] event_merge: no output"
            ((FAIL++))
        fi
    else
        echo "  [FAIL] Solver build (binaries not found)"
        ((FAIL++))
    fi
else
    echo "  [SKIP] No Delphes output"
fi

echo ""
echo "============================================"
echo " Results: $PASS passed, $FAIL failed"
echo "============================================"
echo " Output: $OUT"
exit $FAIL
