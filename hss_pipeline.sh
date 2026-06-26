#!/bin/bash
# Full H→ss̄ pipeline: MG5 → Delphes → higgs-strange-solver (jet_split + event_merge)
# Image: cepc-darkshine.sif (MG5 3.6.7, Delphes with CEPC_4th card)
# Usage:
#   apptainer exec --fakeroot --bind /cefs:/cefs --bind /hpcfs:/hpcfs \
#       cepc-darkshine.sif bash hss_pipeline.sh
#
# Requirements:
#   - Solver source at /hpcfs/cepc/higgsgpu/zhuchunxiang/higgs-strange-solver
#   - Findonnxruntime.cmake already in solver's cmake/ dir (or CEFS copy)
#   - GCC 11 with -fconcepts (solver patched for GCC 11 compatibility)
#
# Output: /tmp/hss_pipeline_out/ (but prefer /cefs/... for persistence)

set +e

# Use CEFS for persistence across apptainer exec calls
# OUT=/cefs/higgs/zhuyifan/DarkSHINE/darkshine-build/hss_validation
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

# ---- Step 3: Build Solver ----
echo ""
echo "--- Step 3: Build higgs-strange-solver ---"
if [ -f hss_delphes.root ]; then
    SOLVER_SRC=${HSS_SOLVER_SRC:-/hpcfs/cepc/higgsgpu/zhuchunxiang/higgs-strange-solver}
    SOLVER_BUILD=$OUT/solver_build
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
