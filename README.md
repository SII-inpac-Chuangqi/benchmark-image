# Benchmark Images — CEPC & LHC

AlmaLinux 9 Apptainer container images for H→ss̄, CEPC, and LHC physics benchmarks.

## Images

| Image | Size | Key Components |
|-------|------|---------------|
| `common/common.sif` | 672M | ROOT 6.40, Python 3.12, onnxruntime 1.16.3, HepMC3 3.3.1, LHAPDF 6.5.6, texlive-base |
| `lhc/lhc.sif` | 763M | common + MG5 3.5.13, Pythia8, Delphes 3.5.0 (CMake, HAS_PYTHIA8) |
| `cepc-darkshine/cepc-darkshine.sif` | 801M | common + Geant4 10.6.3, MG5 3.6.7, CEPC Delphes (CMake), FeynGame |

> `.sif` files are distributed via Git LFS. On lxlogin they're hard-linked from `darkshine-build/` to avoid duplication.

## Quick Start

```bash
# Validate the CEPC image
apptainer exec --fakeroot cepc-darkshine.sif bash validate_cepc.sh

# Run the full H→ss̄ pipeline
apptainer exec --fakeroot --writable-tmpfs cepc-darkshine.sif bash validate_hss.sh
```

## Models

| Model | Location | Description |
|-------|----------|-------------|
| `my_sm` | `models/my_sm/` | Jiang's custom SM with strange Yukawa (yms=0.096). Enables MG5 `h > s s~` processes |
| MG5 card | `cards/proc_card_hss.dat` | Process: `e+e- → ZH, Z → νν, H → ss̄` (my_sm model) |
| MG5 param | `cards/param_card_hss.dat` | Yukawa block with `yms = 0.096` |

## Validation Scripts

| Script | Description |
|--------|-------------|
| `validate_cepc.sh` | 21 static checks (ROOT, Python, MG5, Delphes, PCMs, numpy, etc.) |
| `validate_hss.sh` | Full pipeline: checks + MG5 H→ss̄ + Delphes CEPC_4th + solver (clone→build→jet_split→event_merge) |

Both scripts are self-contained — no `/cefs` paths. Run from any bind-mounted directory inside the container:

```bash
apptainer exec --fakeroot --writable-tmpfs cepc-darkshine.sif bash validate_hss.sh
```

Environment variables: `HSS_WORKDIR` (default `/tmp/hss_validation`), `HSS_NEVENTS` (default 100), `HSS_BRANCH` (default `release/dev/SII-build`).

## Build

Staged Apptainer builds on lxlogin.ihep.ac.cn. Each stage produces a `.sif`, chaining via `Bootstrap: localimage`.

### Common Base (6 stages)

```bash
cd common/
apptainer build --fakeroot common-step1.sif def/step1-dnf-python.def
apptainer build --fakeroot common-step2.sif def/step2-hepmc3.def
apptainer build --fakeroot common-step3.sif def/step3-root.def
apptainer build --fakeroot common-step4.sif def/step4-onnx.def
apptainer build --fakeroot common-step5.sif def/step5-lhapdf.def
apptainer build --fakeroot common.sif def/step6-texlive.def
```

### LHC Overlay (4 stages)

```bash
cd lhc/
apptainer build --fakeroot lhc-step1.sif def/step1-scipy.def
apptainer build --fakeroot lhc-step2.sif def/step2-mg5.def
apptainer build --fakeroot lhc-step3.sif def/step3-delphes.def
apptainer build --fakeroot lhc.sif def/step4-strip.def
```

### CEPC Overlay (4 stages)

```bash
cd cepc-darkshine/
apptainer build --fakeroot cepc-step1.sif def/step1-geant4.def
apptainer build --fakeroot cepc-step2.sif def/step2-mg5.def
apptainer build --fakeroot --bind /hpcfs:/hpcfs --bind /cefs:/cefs cepc-step3.sif def/step3-apps.def
apptainer build --fakeroot cepc-darkshine.sif def/step4-strip.def
```

> Step3 needs `--bind` for FeynGame JAR and CEPC Delphes source on shared filesystems.

## Versions

| Component | Version | Source |
|-----------|---------|--------|
| ROOT | 6.40.00 | codeload |
| Python | 3.12.13 | AlmaLinux 9 |
| onnxruntime | 1.16.3 | codeload |
| HepMC3 | 3.3.1 | GitLab |
| LHAPDF | 6.5.6 | hepforge |
| Geant4 | 10.6.3 | codeload |
| MG5 (LHC) | 3.5.13 | local tarball |
| MG5 (CEPC) | 3.6.7 | local tarball |
| Pythia8 | 8.316 | MG5 builtin |
| LHC Delphes | 3.5.0 | codeload (CMake) |
| CEPC Delphes | custom | hpcfs (CMake, ABI compat) |
| FeynGame | 4.0.0 | CEFS |

## Solver

The `higgs-strange-solver` is cloned at runtime from:
```
https://github.com/SII-inpac-Chuangqi/higgs-strange-solver.git
```
Branch: `release/dev/SII-build` (GCC 11 compatible with `config.h` macros for C++20 features).

## Repository

```
benchmark-image/
├── README.md
├── validate_cepc.sh
├── validate_hss.sh
├── cards/
│   ├── proc_card_hss.dat
│   └── param_card_hss.dat
├── models/my_sm/              # Custom SM with strange Yukawa
├── common/def/                # 6-stage base
├── lhc/def/                   # 4-stage LHC overlay
└── cepc-darkshine/def/        # 4-stage CEPC overlay
```

## Optimization

Images optimized June 2026 (~420M saved vs previous build):
- `texlive-scheme-basic` (149M) → `texlive-base` (~30M)
- Delete `/opt/mg5/tests` (~53M) in LHC + CEPC strip stages
- Delete `G4EMLOW` (~329M on-disk) in CEPC Geant4 stage
- Template preserved (`/opt/mg5/Template`), SudGen only deleted
