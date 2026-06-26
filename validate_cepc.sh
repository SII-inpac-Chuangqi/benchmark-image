#!/bin/bash
# Validation script for CEPC+darkshine image  
# Usage: apptainer exec --fakeroot cepc-darkshine.sif bash validate_cepc.sh

set -e
source /opt/common/bin/thisroot.sh
source /opt/common/bin/geant4.sh 2>/dev/null || true
export PATH=/opt/mg5/bin:/opt/common/bin:$PATH

PASS=0; FAIL=0
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then echo "  [PASS] $n"; ((PASS++)); else echo "  [FAIL] $n"; ((FAIL++)); fi; }

echo "=== CEPC+darkshine Image Validation ==="
echo ""
echo "--- Core ---"
check "ROOT"           which root
check "Python 3.12"    python3.12 --version
check "GCC"            gcc --version
check "pdfTeX"         which pdftex

echo ""
echo "--- Physics Libraries ---"
check "HepMC3"         [ -x /opt/common/bin/HepMC3-config ]
check "LHAPDF"         which lhapdf-config
check "onnxruntime"    python3.12 -c "import onnxruntime"

echo ""
echo "--- Generator Tools ---"
check "MG5_aMC 3.6.7"  [ -f /opt/mg5/bin/mg5_aMC ]
check "Pythia8"        [ -f /opt/mg5/HEPTools/pythia8/lib/libpythia8.so ]
check "Pythia8 MG5"    [ -f /opt/mg5/HEPTools/mg5amc_py8_interface/MG5aMC_PY8_interface ]

echo ""
echo "--- Delphes Fast Simulation ---"
check "DelphesHepMC2"  [ -x /opt/common/bin/DelphesHepMC2 ]
check "DelphesROOT"    [ -x /opt/common/bin/DelphesROOT ]
check "DelphesPythia8" [ -x /opt/common/bin/DelphesPythia8 ]
check "CEPC card"      [ -f /opt/common/cards/delphes_card_CEPC.tcl ]

echo ""
echo "--- Python HEP Stack ---"
check "numpy"          python3.12 -c "import numpy"
check "awkward"        python3.12 -c "import awkward"
check "uproot"         python3.12 -c "import uproot"
check "matplotlib"     python3.12 -c "import matplotlib"
check "ROOT Python"    python3.12 -c "import ROOT"

echo ""
echo "--- FeynGame ---"
check "FeynGame jar"   [ -f /opt/common/feyngame/bin/FeynGame-8.jar ]

echo ""
echo "============================================"
echo " Results: $PASS passed, $FAIL failed"
echo "============================================"
exit $FAIL
