# DarkSHINE Simulation Container Image

AlmaLinux 9 container image with Geant4 10.6.3, ROOT 6.30.06, ACTS (ykrsama/xuliang-v30), and ONNX Runtime.

## Files

| File | Type | Description |
|------|------|-------------|
| `Dockerfile` | Docker | Single-stage full build |
| `darkshine.def` | Apptainer | Single-stage full build |
| `step1-dnf-geant4.def` | Apptainer | Stage 1: system packages + Geant4 |
| `step2-root.def` | Apptainer | Stage 2: ROOT (from step1 .sif) |
| `step3-acts.def` | Apptainer | Stage 3: ACTS (from step2 .sif) |
| `step4-onnx.def` | Apptainer | Stage 4: ONNX Runtime (from step3 .sif) |
| `validate_reco.sh` | Script | Reconstruction validation (builds + runs DAna) |

## Quick Start — Docker

```bash
docker build -t darkshine-simulation:rhel9 .

# With GFW workaround (codeload fallback)
docker build --build-arg USE_CODELOAD=1 -t darkshine-simulation:rhel9 .

# Run
docker run --rm -it darkshine-simulation:rhel9
```

## Quick Start — Apptainer (single-stage)

```bash
apptainer build --fakeroot darkshine.sif darkshine.def

# Run
apptainer run darkshine.sif
```

## Multi-Stage Apptainer Build

For environments where the full build exceeds time/memory limits, build in stages:

```bash
# Stage 1: system packages + Geant4
apptainer build --fakeroot darkshine-step1.sif step1-dnf-geant4.def

# Stage 2: ROOT
apptainer build --fakeroot darkshine-step2.sif step2-root.def

# Stage 3: ACTS
apptainer build --fakeroot darkshine-step3.sif step3-acts.def

# Stage 4: ONNX Runtime
apptainer build --fakeroot darkshine.sif step4-onnx.def
```

**Important:** Between restarts, do NOT delete `tmp/` — it caches OCI image layers. Only remove the `.sif` file.

## Contents

| Component | Version | Install Path |
|-----------|---------|-------------|
| AlmaLinux | 9 | base OS |
| Geant4 | 10.6.3 | `/opt/darkshine` |
| ROOT | 6.30.06 | `/opt/darkshine` |
| ACTS | ykrsama/xuliang-v30 | `/opt/darkshine` |
| ONNX Runtime | 1.19.2 (Docker) / 1.16.3 (Apptainer) | `/opt/darkshine` |

## Environment

On start, `source /opt/darkshine/setup.sh` is sourced automatically, which sets up Geant4 and ROOT environments (PATH, LD_LIBRARY_PATH, geant4.sh, thisroot.sh).

## Reconstruction Validation

The `validate_reco.sh` script verifies that the container can build and run DarkSHINE reconstruction (DAna). It checks:

1. Environment: cmake, g++, ROOT, Geant4, ACTS headers
2. Build: clones darkshine-simulation, builds DAna (minimal config with ACTS)
3. Runtime: runs DAna on test data, validates output tree

```bash
# Inside the container
source /opt/darkshine/setup.sh

# Auto-clone mode (clones darkshine-simulation to /tmp/ds-test)
./validate_reco.sh

# Or point to an existing repo
./validate_reco.sh /path/to/darkshine-simulation
```

**Expected output**: DAna completes without crash, output ROOT file has `dp` tree with >0 entries. With ACTS-based tracking (seed=1, find=1, fit=2), expect ~99% tracking efficiency for 8 GeV electrons at B=−1.5T.

## Network Notes

- `codeload.github.com` is used as the default download source (works behind GFW).
- `registry.access.redhat.com` and `quay.io` are reachable from lxlogin.
- Dockerfile supports `USE_CODELOAD=0` build arg for direct github.com access.

## See Also

- [darkshine-simulation](https://github.com/SII-inpac-Chuangqi/darkshine-simulation) — simulation & reconstruction code
- [darkshine-analysis](https://github.com/SII-inpac-Chuangqi/darkshine-analysis) — analysis & limit setting
