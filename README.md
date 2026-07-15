# Benchmark Images — CEPC & LHC

AlmaLinux 9 Apptainer container images for H→ss̄, DarkSHINE, CEPC, and LHC physics benchmarks.

## Images

| Image | Size | Key Components |
|-------|------|---------------|
| `common/common.sif` | 672M | ROOT 6.40, Python 3.12, onnxruntime 1.16.3, HepMC3 3.3.1, LHAPDF 6.5.6, texlive-base |
| `lhc/lhc.sif` | 765M | common + MG5 3.5.13, Pythia8, Delphes 3.5.0 (CMake, HAS_PYTHIA8), pyhepmc |
| `cepc-darkshine/cepc-darkshine.sif` | 801M | common + Geant4 10.6.3, MG5 3.6.7, CEPC Delphes (CMake), FeynGame |

> `.sif` files are distributed via Git LFS. On lxlogin they're hard-linked from `darkshine-build/`.

## Quick Start

```bash
# H->ss validation (from benchmark-image directory)
apptainer exec --fakeroot --writable-tmpfs --bind $PWD:/mnt/bi \
    cepc-darkshine/cepc-darkshine.sif bash validate_hss.sh

# LHC image validation (static checks)
apptainer exec --fakeroot lhc/lhc.sif bash validate_lhc.sh

# DarkSHINE simulation (1k events, 8 GeV, 1.5T)
apptainer exec --fakeroot --writable-tmpfs --bind $PWD:/mnt/bi \
    cepc-darkshine/cepc-darkshine.sif bash validate_darkshine.sh
```

Environment variables: `HSS_WORKDIR`, `HSS_NEVENTS`, `HSS_BRANCH`, `MY_SM_PATH`.

## Models & Cards

| Item | Location | Description |
|------|----------|-------------|
| `my_sm` | `models/my_sm/` | Custom SM with strange Yukawa (yms=0.096). Auto-detected at `/mnt/bi/models/my_sm`. |
| MG5 card | `cards/proc_card_hss.dat` | Process: `e+e- → ZH, Z → νν, H → ss̄` |
| MG5 param | `cards/param_card_hss.dat` | Yukawa block with `yms = 0.096` |

## Validation Scripts

| Script | Checks | Pipeline |
|--------|--------|----------|
| `validate_cepc.sh` | 21 | None (static availability) |
| `validate_hss.sh` | 18 | MG5 → Delphes → Solver clone+build → jet_split → event_merge → mjj plot |
| `validate_lhc.sh` | 21 | None (static availability) |
| `validate_darkshine.sh` | 12 | Dependencies → Clone DS → Build → DSimu (1k events, 8 GeV, 1.5T) |

Summary format: `Results: X passed, Y failed`.

## Build

Staged Apptainer builds on lxlogin.ihep.ac.cn (6-stage common, 4-stage overlays). Defs in per-image directories.

## Versions

| Component | Version | Source |
|-----------|---------|--------|
| ROOT | 6.40.00 | codeload |
| Geant4 | 10.6.3 | codeload |
| MG5 (CEPC) | 3.6.7 | local tarball, madevent.macro syntax |
| MG5 (LHC) | 3.5.13 | local tarball |
| Pythia8 | 8.316 | MG5 builtin |
| LHC Delphes | 3.5.0 | codeload (CMake) |
| CEPC Delphes | custom | hpcfs (CMake, ABI compat) |
| Solver | release/dev/SII-build | GitHub, GCC 11 compat with config.h macros |
| FeynGame | 4.0.0 | CEFS |

## Optimization

- `texlive-scheme-basic` (149M) → `texlive-base` (~30M)
- Delete `/opt/mg5/tests` (~53M) in strip stages
- Delete `G4EMLOW` (~329M) in Geant4 stage
- Template preserved, SudGen only deleted

Total: ~420M saved vs previous build.
