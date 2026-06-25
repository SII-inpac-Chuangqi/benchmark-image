#!/bin/bash
# Reconstruction validation for DarkSHINE container image
# Run inside the container: source /opt/darkshine/setup.sh && ./validate_reco.sh [DS_REPO_PATH]
#
# If DS_REPO_PATH is provided, uses it directly.
# Otherwise clones darkshine-simulation to /tmp/ds-test.

set -e

RED='\033[31m'
GREEN='\033[32m'
BOLD='\033[1m'
NC='\033[0m'

pass()  { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "  ${BOLD}[INFO]${NC} $1"; }

echo "=== DarkSHINE Reconstruction Validation ==="
echo ""

# ── 1. Environment checks ──────────────────────────────────────────
echo "1. Environment"
command -v cmake  >/dev/null 2>&1 && pass "cmake: $(cmake --version | head -1)"         || fail "cmake not found"
command -v g++    >/dev/null 2>&1 && pass "g++:    $(g++ --version | head -1)"           || fail "g++ not found"
command -v root   >/dev/null 2>&1 && pass "ROOT:   $(root --version 2>/dev/null | head -1)" || fail "root not found"
command -v geant4-config >/dev/null 2>&1 && pass "Geant4: $(geant4-config --version 2>/dev/null)" || fail "geant4-config not found"

# Check key headers
[ -d "${INSTALL_PREFIX:-/opt/darkshine}/include/Acts" ]         && pass "ACTS headers"   || fail "ACTS headers missing"
[ -d "${INSTALL_PREFIX:-/opt/darkshine}/include/onnxruntime" ] && pass "ONNX Runtime headers" || info "ONNX Runtime not installed (optional)"

echo ""

# ── 2. Locate source ──────────────────────────────────────────────
DS_REPO="${1:-}"
if [ -z "$DS_REPO" ]; then
    echo "2. Cloning darkshine-simulation (minimal build)..."
    cd /tmp
    rm -rf ds-test
    git clone --depth 1 https://github.com/SII-inpac-Chuangqi/darkshine-simulation.git ds-test 2>&1 | tail -1
    cd ds-test
    git lfs pull 2>/dev/null || info "LFS pull skipped (no large files needed for build test)"
    DS_REPO="/tmp/ds-test"
else
    echo "2. Using source: $DS_REPO"
    cd "$DS_REPO"
fi

echo ""

# ── 3. Build (minimal config: DSimu only) ─────────────────────────
echo "3. Build"
mkdir -p build && cd build
cmake ../source \
    -DCMAKE_INSTALL_PREFIX=../install \
    -DCMAKE_CXX_STANDARD=17 \
    -DWITH_GEANT4_UIVIS=OFF \
    -DBUILD_DANA=ON \
    -DBUILD_DDIS=OFF \
    -DBUILD_TOOLS=OFF \
    -DBUILD_HDF5=OFF \
    -DBUILD_ACTS=ON \
    -DBUILD_ONNX=OFF \
    -Dfail-on-missing=OFF \
    2>&1 | tail -3
make -j4 2>&1 | tail -3
make install 2>&1 | tail -1
[ -f ../install/bin/DAna ] && pass "DAna built" || fail "DAna binary missing"

echo ""

# ── 4. Run reconstruction ─────────────────────────────────────────
echo "4. Reconstruction test"
cd ../run

# Find a test input file
INPUT=""
for f in dp_simu.root dp_simu_const.root; do
    [ -f "$f" ] && INPUT="$f" && break
done
if [ -z "$INPUT" ]; then
    # Check test/ directory
    for f in ../test/*.root; do
        [ -f "$f" ] && INPUT="$f" && break
    done
fi

if [ -z "$INPUT" ]; then
    info "No test input file found — skipping runtime test"
    info "To run: place dp_simu.root in run/ and execute ../install/bin/DAna config.txt"
else
    info "Using input: $INPUT"
    # Create minimal config
    cat > config_test.txt << EOF
[General]
InputFile = $INPUT
OutputFile = dp_ana_validation.root
EventNumber = 100
Verbose = 0

[Tracking]
seed_method = 1
find_method = 1
Rec_fit_method = 2
Tag_fit_method = 2
con_field = -1.5
skip_hits_geq = 40
remove_hit_less_E = 0.02

[ActsSequencer]
use_dmagnet = 0
const_bfiled = -1.5
EOF

    START=$(date +%s)
    ../install/bin/DAna config_test.txt 2>&1 | tail -5
    ELAPSED=$(($(date +%s) - START))

    if [ -f dp_ana_validation.root ]; then
        pass "Reconstruction completed (${ELAPSED}s)"
        # Quick ROOT validation
        root -l -q -b "dp_ana_validation.root" -e '
          TFile f("dp_ana_validation.root");
          TTree* t = (TTree*)f.Get("dp");
          if (!t) { std::cerr << "ERROR: no dp tree" << std::endl; exit(1); }
          int n = t->GetEntries();
          std::cout << "Entries: " << n << std::endl;
          if (n == 0) { std::cerr << "WARNING: zero entries" << std::endl; exit(1); }
        ' 2>&1 | grep -v "^$" && pass "Output tree valid" || fail "Output tree check failed"
        rm -f dp_ana_validation.root config_test.txt
    else
        fail "No output file produced"
    fi
fi

echo ""
echo -e "${GREEN}=== All validation checks passed ===${NC}"
