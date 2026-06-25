# Benchmark Images — CEPC & LHC

AlmaLinux 9 Apptainer images for DarkSHINE, CEPC, and LHC physics benchmarks.

## Images

| Image | Final SIF | Content |
|-------|-----------|---------|
| Common base | `common.sif` | ROOT 6.40.00, Python 3.12, onnxruntime 1.16.3, HepMC3 3.3.1, TeX Live |
| LHC | `lhc.sif` | common + LHAPDF 6.5.6, MG5_aMC 3.5.13, Pythia 8.316, Delphes 3.5.0 |
| CEPC + darkshine | `cepc-darkshine.sif` | common + Geant4 10.6.3, MG5_aMC 3.6.3, CEPC Delphes, FeynGame 3.0.0 |

## Build

Staged Apptainer builds on lxlogin.ihep.ac.cn. Each stage produces a `.sif` and uses `Bootstrap: localimage` to chain from the previous stage.

### Quick Start

```bash
# 1. Build common base (5 stages)
cd common/
apptainer build --fakeroot common-step1.sif step1-dnf-python.def
apptainer build --fakeroot common-step2.sif step2-hepmc3.def
apptainer build --fakeroot common-step3.sif step3-root.def
apptainer build --fakeroot common-step4.sif step4-onnx.def
apptainer build --fakeroot common.sif step5-texlive.def

# 2. Build LHC overlay (requires MG5_aMC_v3.5.13.tar.gz in lhc/ directory)
cd ../lhc/
apptainer build --fakeroot lhc-step1.sif step1-lhapdf.def
apptainer build --fakeroot lhc-step2.sif step2-mg5.def
apptainer build --fakeroot lhc-step3.sif step3-delphes.def
apptainer build --fakeroot lhc.sif step4-strip.def
```

### Prerequisites

- lxlogin: Apptainer 1.5.0+ with `--fakeroot`
- Storage: CEFS (`/cefs/higgs/<user>/`)
- Source tarballs for MG5_aMC must be placed in the build directory (Launchpad download blocked by GFW)

## Validation

```bash
apptainer exec --fakeroot lhc.sif bash validate.sh
```

## Directory Layout

```
benchmark-image/
├── README.md
├── validate.sh
├── common/                    # Shared base (5 stages)
│   ├── step1-dnf-python.def
│   ├── step2-hepmc3.def
│   ├── step3-root.def
│   ├── step4-onnx.def
│   └── step5-texlive.def
├── lhc/                       # LHC overlay (4 stages)
│   ├── step1-lhapdf.def
│   ├── step2-mg5.def
│   ├── step3-delphes.def
│   └── step4-strip.def
├── cepc-darkshine/            # CEPC + darkshine (to be built)
└── darkshine/                 # Original darkshine-only image (historical)
```

## Versions

| Component | Version |
|-----------|---------|
| ROOT | 6.40.00 |
| Python | 3.12.13 |
| onnxruntime | 1.16.3 |
| HepMC3 | 3.3.1 |
| LHAPDF | 6.5.6 |
| MG5_aMC | 3.5.13 |
| Pythia8 | 8.316 |
| Delphes | 3.5.0 |
