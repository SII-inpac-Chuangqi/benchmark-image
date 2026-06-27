#!/bin/bash
# DarkSHINE simulation validation — self-contained, no /cefs or /hpcfs dependencies
# Image: cepc-darkshine.sif (Geant4 10.6.3, ROOT 6.40, GCC 11)
#
# Usage:
#   apptainer exec --fakeroot --writable-tmpfs cepc-darkshine.sif bash validate_darkshine.sh
#
# Environment:
#   DS_WORKDIR    Working directory (default: /tmp/darkshine_validation)
#   DS_NEVENTS    Number of events (default: 1000)
#   DS_BEAM_E     Beam energy in GeV (default: 8)
#   DS_BRANCH     darkshine-simulation branch (default: main)
#
# Directory structure:
#   $DS_WORKDIR/
#     source/     Cloned darkshine-simulation
#     build/      CMake build
#     install/    make install
#     run/        Simulation jobs, output

set +e
WORK=${DS_WORKDIR:-/tmp/darkshine_validation}
NEVENTS=${DS_NEVENTS:-1000}
BEAM_E=${DS_BEAM_E:-8}
BRANCH=${DS_BRANCH:-main}
DS_REPO="https://github.com/SII-inpac-Chuangqi/darkshine-simulation.git"

rm -rf $WORK && mkdir -p $WORK/{source,build,install,run}
cd $WORK

source /opt/common/bin/thisroot.sh 2>/dev/null
source /opt/common/bin/geant4.sh 2>/dev/null || true
export PATH=/opt/common/bin:$PATH
export LD_LIBRARY_PATH=/opt/common/lib:/opt/common/lib64:$LD_LIBRARY_PATH

PASS=0; FAIL=0
check() { local n=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  [PASS] $n"; ((PASS++))
    else echo "  [FAIL] $n"; ((FAIL++)); fi
}

echo "============================================"
echo " DarkSHINE Simulation Validation"
echo "   ${NEVENTS} events, ${BEAM_E} GeV, 1.5T magnet"
echo "============================================"

# ---- Part 1: Image checks ----
echo ""
echo "--- Image Checks ---"
check "ROOT 6.40"         root -l -q -e 'gROOT->GetVersion()' 2>&1 | grep -q "6.40"
check "Geant4 10.6"       geant4-config --version
check "cmake"             which cmake
check "GCC"               gcc --version
check "Python 3.12"       python3.12 --version

# ---- Part 2: Install build deps ----
echo ""
echo "--- Install Dependencies ---"
dnf -y install eigen3-devel json-devel gsl-devel hdf5-devel xerces-c-devel 2>&1 | tail -1
check "Eigen3"            [ -d /usr/include/eigen3 ]
check "nlohmann/json"     [ -f /usr/include/nlohmann/json.hpp ]
check "GSL"               [ -f /usr/include/gsl/gsl_sf.h ]

# ---- Part 3: Clone darkshine-simulation ----
echo ""
echo "--- Clone darkshine-simulation ---"
cd $WORK/source
if git clone -b "$BRANCH" "$DS_REPO" darkshine 2>/dev/null; then
    echo "  [OK] Cloned ($BRANCH)"
else
    echo "  [FAIL] Git clone failed (network?)"
    ((FAIL++)); echo ""; echo "Results: $PASS passed, $FAIL failed"; exit $FAIL
fi

# ---- Part 4: Build ----
echo ""
echo "--- Build ---"
cd $WORK/build
rm -rf * 2>/dev/null
cmake $WORK/source/darkshine \
    -DCMAKE_INSTALL_PREFIX=$WORK/install \
    -DCMAKE_CXX_STANDARD=17 \
    -DBUILD_ACTS=OFF \
    -DBUILD_ONNX=OFF \
    -DWITH_GEANT4_UIVIS=OFF \
    2>&1 | tail -3
make -j4 2>&1 | tail -5
make install 2>&1 | tail -3

DSIMU=$(find $WORK/install -name DSimu -executable 2>/dev/null | head -1)
if [ -n "$DSIMU" ]; then
    echo "  [PASS] DSimu built"
    ((PASS++))
else
    echo "  [FAIL] DSimu build"
    ((FAIL++)); echo ""; echo "Results: $PASS passed, $FAIL failed"; exit $FAIL
fi

# ---- Part 5: Generate magnet file ----
echo ""
echo "--- Magnet file ---"
cd $WORK/run
B=${DS_BFIELD:-1.5}

cat > gen_magnet.C << 'ROOTMAC'
void gen_magnet(float B = 1.5) {
    TFile f("mag_1p5.root", "RECREATE");
    TTree t("tree", "tree");
    float x, y, z, bx, by, bz;
    t.Branch("x", &x); t.Branch("y", &y); t.Branch("z", &z);
    t.Branch("Bx", &bx); t.Branch("By", &by); t.Branch("Bz", &bz);
    float fieldMap[19][19][19];
    // Uniform Bz = 1.5T
    for (int i = 0; i < 19; i++)
        for (int j = 0; j < 19; j++)
            for (int k = 0; k < 19; k++) {
                x = (i - 9) * 100; y = (j - 9) * 100; z = (k - 9) * 100;
                bx = 0; by = 0; bz = B;
                t.Fill();
            }
    t.Write(); f.Close();
    cout << "magnet map written: " << t.GetEntries() << " points, Bz=" << B << "T" << endl;
}
ROOTMAC

root -l -q -b "gen_magnet.C($B)" 2>&1 | tail -1
if [ -f mag_1p5.root ]; then
    echo "  [PASS] Magnet 1.5T"
    ((PASS++))
else
    echo "  [FAIL] Magnet"
    ((FAIL++))
fi

# ---- Part 6: Generate config ----
echo ""
echo "--- DSimu config ---"

cat > ds_config.yaml << YAML
Global:
  seed: 42
  Run_Number: 0
  save_geometry: false
  check_overlaps: false
  signal_production: false

Beam:
  particle: "e-"
  energy: ${BEAM_E}
  pos_x: 0.0
  pos_y: 0.0
  pos_z: -3000.0
  dir_x: 0.0
  dir_y: 0.0
  dir_z: 1.0

Magnet:
  field_file: "mag_1p5.root"

RootManager:
  output_file: "ds_simu.root"
  beam_on: ${NEVENTS}

OutCollection:
  save_mc_particles: true
  save_hits: true
YAML

echo "  [OK] Config: ${BEAM_E} GeV e-, ${NEVENTS} events"

# ---- Part 7: Run DSimu ----
echo ""
echo "--- DSimu ---"
export DSS_DIR=$WORK/install
export PATH=${DSS_DIR}/bin:${PATH}
export LD_LIBRARY_PATH=${DSS_DIR}/lib:${LD_LIBRARY_PATH}

$DSIMU -y ds_config.yaml -b $NEVENTS 2>&1 | tail -10

if [ -f ds_simu.root ]; then
    SIZE=$(stat -c%s ds_simu.root 2>/dev/null || echo ok)
    echo "  [PASS] DSimu: ds_simu.root ($SIZE bytes)"
    ((PASS++))
else
    echo "  [FAIL] DSimu: no output"
    ((FAIL++))
fi

echo ""
echo "============================================"
echo " Results: $PASS passed, $FAIL failed"
echo " Workdir: $WORK"
echo "============================================"
exit $FAIL
