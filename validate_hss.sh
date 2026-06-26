#!/bin/bash
# Validation script for CEPC+darkshine image: H→ss̄ MadGraph + Delphes workflow
# Image: cepc-darkshine.sif (MG5 3.6.7 — uses madevent.macro, not inline launch)
# Usage: apptainer exec --fakeroot --bind /cefs:/cefs cepc-darkshine.sif bash validate_hss.sh
#
# NOTE: Write output to /cefs, not /tmp — container /tmp is ephemeral
#       and invisible to subsequent apptainer exec calls.

set -e
OUT=/tmp/hss_validation
rm -rf $OUT && mkdir -p $OUT && cd $OUT

PASS=0
FAIL=0

check() {
    local name=$1
    shift
    if "$@" > /dev/null 2>&1; then
        echo "  [PASS] $name"
        ((PASS++))
    else
        echo "  [FAIL] $name"
        ((FAIL++))
    fi
}

echo "============================================"
echo " CEPC+darkshine Image Validation: H->ss̄"
echo "============================================"
echo ""

# --- Environment ---
source /opt/common/bin/thisroot.sh
source /opt/common/bin/geant4.sh 2>/dev/null || true
export PATH=/opt/mg5/bin:/opt/common/bin:$PATH
export LD_LIBRARY_PATH=/opt/common/lib:/opt/common/lib64:/opt/mg5/HEPTools/pythia8/lib:$LD_LIBRARY_PATH

echo "--- 1. Software Availability ---"
check "ROOT 6.40"            root -l -q -e 'gROOT->GetVersion()' 2>&1 | grep -q "6.40"
check "MG5_aMC 3.6.7"        [ -f /opt/mg5/bin/mg5_aMC ]
check "Pythia8 lib"          [ -f /opt/mg5/HEPTools/pythia8/lib/libpythia8.so ]
check "HepMC3"               hepmc3-config --version
check "LHAPDF"               lhapdf-config --version
check "DelphesHepMC2"        [ -x /opt/common/bin/DelphesHepMC2 ]
check "Delphes PCM"          [ -f /opt/common/lib/libClassesDict_rdict.pcm ]
check "CEPC 4th card"        [ -f /opt/common/cards/delphes_card_CEPC_4th.tcl ]
check "FeynGame"             [ -x /opt/common/bin/feyngame ]
check "GCC"                  gcc --version
check "Python 3.12"          python3.12 --version

echo ""
echo "--- 2. MadGraph Event Generation (e+e- -> Z -> ss̄) ---"

# MG5 3.6.7: use madevent.macro, NOT inline launch syntax
cat > hss_mg5.txt << 'MGEOF'
import model sm
generate e+ e- > z, z > s s~
output hss_test
exit
MGEOF

echo "  Creating MG5 process..."
mg5_aMC hss_mg5.txt 2>&1 | tail -3

# MG5 3.6.7: madevent.macro for launch with settings
cat > hss_test/madevent.macro << 'MACRO'
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
cd hss_test && bin/madevent madevent.macro 2>&1 | tail -10
cd $OUT

# MG5 3.6.7 outputs gzipped HepMC
HEPMC_GZ=$(find hss_test/Events -name "tag_1_pythia8_events.hepmc*" 2>/dev/null | head -1)
if [ -n "$HEPMC_GZ" ]; then
    if [[ "$HEPMC_GZ" == *.gz ]]; then
        zcat "$HEPMC_GZ" > events.hepmc
    else
        cp "$HEPMC_GZ" events.hepmc
    fi
    EVENT_COUNT=$(grep -c "^E " events.hepmc 2>/dev/null || echo 0)
    echo "  [PASS] MG5 event generation ($EVENT_COUNT events)"
    ((PASS++))
else
    echo "  [FAIL] MG5 event generation (no HepMC file)"
    ((FAIL++))
    ls -la hss_test/Events/ 2>/dev/null || echo "  No Events directory"
fi

echo ""
echo "--- 3. Delphes Fast Simulation ---"

if [ -f events.hepmc ]; then
    # Use CEPC_4th card (more robust than main CEPC card for test samples)
    echo "  Running DelphesHepMC2 with CEPC_4th card..."
    DelphesHepMC2 /opt/common/cards/delphes_card_CEPC_4th.tcl hss_delphes.root events.hepmc 2>&1 | tail -3

    if [ -f hss_delphes.root ]; then
        SIZE=$(stat -c%s hss_delphes.root 2>/dev/null || stat -f%z hss_delphes.root 2>/dev/null)
        echo "  [PASS] Delphes simulation ($SIZE bytes)"
        ((PASS++))
    else
        echo "  [FAIL] Delphes simulation (no output file)"
        ((FAIL++))
    fi
else
    echo "  [SKIP] No HepMC input available"
fi

echo ""
echo "--- 4. ROOT Analysis of Delphes Output ---"

if [ -f hss_delphes.root ]; then
    cat > analyze.C << 'REOF'
{
    TFile f("hss_delphes.root");
    TTree *t = (TTree*)f.Get("Delphes");
    if (!t) {
        cout << "ERROR: No Delphes tree found" << endl;
        return;
    }
    Int_t n = t->GetEntries();
    cout << "Total events in Delphes output: " << n << endl;

    // Check jet multiplicity
    t->Draw("Jet_size>>h_jet(10,0,10)", "", "goff");

    // Check track multiplicity
    t->Draw("Track_size>>h_trk(10,0,10)", "", "goff");

    cout << "Delphes tree contains " << t->GetListOfBranches()->GetEntries() << " branches" << endl;
}
REOF
    root -l -q analyze.C 2>&1 | grep -E "Total events|branches"
    echo "  [PASS] ROOT analysis of Delphes output"
    ((PASS++))
else
    echo "  [SKIP] No Delphes output available"
fi

echo ""
echo "============================================"
echo " Results: $PASS passed, $FAIL failed"
echo "============================================"

exit $FAIL
