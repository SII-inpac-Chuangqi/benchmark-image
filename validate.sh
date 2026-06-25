#!/bin/bash
# Validation script for LHC benchmark image
# Tests: ROOT, HepMC3, LHAPDF, Pythia8, MG5_aMC, Delphes

set -e
PASS=0
FAIL=0

check() {
    local name=$1 cmd=$2
    if eval "$cmd" > /dev/null 2>&1; then
        echo "  [PASS] $name"
        ((PASS++))
    else
        echo "  [FAIL] $name"
        ((FAIL++))
    fi
}

echo "=== LHC Benchmark Image Validation ==="
echo ""

echo "--- Common Base ---"
check "ROOT 6.40.00"            'root --version 2>&1 | grep -q "6.40"'
check "Python 3.12"             'python3.12 --version 2>&1 | grep -q "3.12"'
check "numpy"                   'python3.12 -c "import numpy; print(numpy.__version__)"'
check "scipy"                   'python3.12 -c "import scipy"'
check "matplotlib"              'python3.12 -c "import matplotlib"'
check "uproot"                  'python3.12 -c "import uproot"'
check "awkward"                 'python3.12 -c "import awkward"'
check "HepMC3"                  'hepmc3-config --version 2>&1 | grep -q "."'
check "onnxruntime"             'python3.12 -c "import onnxruntime"'
check "pdfTeX"                  'which pdftex'

echo ""
echo "--- LHC Specific ---"
check "LHAPDF 6.5.6"            'lhapdf-config --version 2>&1 | grep -q "6.5.6"'
check "MG5_aMC"                 '[ -f /opt/mg5/bin/mg5_aMC ]'
check "Pythia8 8.316"           '[ -f /opt/mg5/HEPTools/pythia8/lib/libpythia8.so ]'
check "DelphesHepMC2"           '[ -x /opt/common/bin/DelphesHepMC2 ]'
check "DelphesHepMC3"           '[ -x /opt/common/bin/DelphesHepMC3 ]'
check "DelphesPythia8"          '[ -x /opt/common/bin/DelphesPythia8 ]'
check "DelphesROOT"             '[ -x /opt/common/bin/DelphesROOT ]'
check "CEPC card"               '[ -f /opt/common/cards/delphes_card_CEPC.tcl ]'

echo ""
echo "--- Pythia8 Functionality ---"
cat > /tmp/test_pythia8.py << 'PYEOF'
import sys
sys.path.insert(0, '/opt/mg5/HEPTools/pythia8/lib')
import pythia8
pythia = pythia8.Pythia()
pythia.readString("Beams:eCM = 8000.")
pythia.init()
print("Pythia8 initialized successfully")
PYEOF
check "Pythia8 Python bindings" 'python3.12 /tmp/test_pythia8.py'

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
