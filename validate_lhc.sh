#!/bin/bash
# LHC image validation — static software checks
# Image: lhc.sif (MG5 3.5.13, Delphes 3.5.0, LHAPDF)
#
# Usage:
#   apptainer exec --fakeroot lhc.sif bash validate_lhc.sh

set +e

# ---- Container environment ----
source /opt/common/bin/thisroot.sh 2>/dev/null || true
export PATH=/opt/mg5/bin:/opt/common/bin:$PATH
export LD_LIBRARY_PATH=/opt/common/lib:/opt/common/lib64:/opt/mg5/HEPTools/pythia8/lib:${LD_LIBRARY_PATH}

PASS=0; FAIL=0
check() {
    local n=$1; shift
    if "$@" >/dev/null 2>&1; then
        echo "  [PASS] $n"; ((PASS++))
    else
        echo "  [FAIL] $n"; ((FAIL++))
    fi
}

echo "============================================"
echo " LHC Image Validation"
echo "============================================"

# ---- Part 1: Image checks ----
echo ""
echo "--- Image Checks ---"
check "ROOT"              which root
check "Python 3.12"       python3.12 --version
check "GCC"               gcc --version

echo ""
echo "--- Physics Libraries ---"
check "HepMC3"            [ -x /opt/common/bin/HepMC3-config ]
check "LHAPDF"            which lhapdf-config

echo ""
echo "--- Generator Tools ---"
check "MG5_aMC 3.5.13"    [ -f /opt/mg5/bin/mg5_aMC ]
check "Pythia8"           [ -f /opt/mg5/HEPTools/pythia8/lib/libpythia8.so ]
check "Pythia8 MG5"       [ -f /opt/mg5/HEPTools/MG5aMC_PY8_interface/MG5aMC_PY8_interface ]

echo ""
echo "--- Delphes Fast Simulation ---"
check "DelphesHepMC3"     [ -x /opt/common/bin/DelphesHepMC3 ]
check "DelphesLHEF"       [ -x /opt/common/bin/DelphesLHEF ]
check "ATLAS card"        [ -f /opt/common/cards/delphes_card_ATLAS.tcl ]

echo ""
echo "--- Delphes PCM ---"
check "ClassesDict PCM"   [ -f /opt/common/lib/libClassesDict_rdict.pcm ]
check "ExRoot PCM"        [ -f /opt/common/lib/libExRootAnalysisDict_rdict.pcm ]
check "ModulesDict PCM"   [ -f /opt/common/lib/libModulesDict_rdict.pcm ]

echo ""
echo "--- Python HEP Stack ---"
check "numpy"             python3.12 -c "import numpy"
check "awkward"           python3.12 -c "import awkward"
check "uproot"            python3.12 -c "import uproot"
check "matplotlib"        python3.12 -c "import matplotlib"
check "scipy"             python3.12 -c "import scipy"
check "ROOT Python"       python3.12 -c "import ROOT"

echo ""
echo "--- Python Utilities ---"
check "pyhepmc"           python3.12 -c "import pyhepmc"

echo ""
echo "============================================"
echo " Results: $PASS passed, $FAIL failed"
echo "============================================"
exit $FAIL
