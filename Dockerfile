# DarkSHINE Simulation — RHEL 9 container image
# Build: docker build -t darkshine-simulation:rhel9 .
# Or:    apptainer build --fakeroot darkshine.sif Dockerfile
#
# For GFW environments (codeload fallback):
#   docker build --build-arg USE_CODELOAD=1 -t darkshine-simulation:rhel9 .

FROM quay.io/almalinux/almalinux:9

LABEL maintainer="SII-inpac"
LABEL description="DarkSHINE Simulation"

ARG USE_CODELOAD=0

# ── System packages ─────────────────────────────────────────────
RUN dnf -y update && \
    dnf -y install dnf-plugins-core && \
    dnf -y install epel-release && \
    dnf config-manager --set-enabled crb && \
    dnf -y install \
        cmake gcc-c++ gcc make git wget tar gzip which \
        mesa-libGL-devel mesa-libGLU-devel \
        libX11-devel libXpm-devel libXft-devel libXext-devel libXt-devel libXmu-devel \
        libGLEW glew-devel ftgl-devel \
        gsl-devel yaml-cpp-devel xerces-c-devel nlohmann-json-devel eigen3-devel \
        hdf5-devel boost-devel \
        protobuf-devel protobuf-compiler \
        openssl-devel expat-devel zlib-devel pcre2-devel xxhash-devel libzstd-devel lz4-devel && \
    dnf clean all

ENV INSTALL_PREFIX=/opt/darkshine
ENV PATH=${INSTALL_PREFIX}/bin:${PATH}
ENV LD_LIBRARY_PATH=${INSTALL_PREFIX}/lib:${INSTALL_PREFIX}/lib64:${LD_LIBRARY_PATH}

WORKDIR /tmp/build

# ── Download helper ─────────────────────────────────────────────
# When USE_CODELOAD=1, download from codeload.github.com (GFW workaround)
COPY <<'EOFDL' /usr/local/bin/ghdl
#!/bin/bash
set -e
if [ "${USE_CODELOAD}" = "1" ]; then
    URL="https://codeload.github.com/$1/legacy.tar.gz/$2"
else
    URL="https://github.com/$1/archive/$2.tar.gz"
fi
echo "Downloading ${URL} ..."
curl -sL --connect-timeout 30 --max-time 900 -o "$3" "${URL}"
echo "OK ($(ls -lh $3 | awk '{print $5}'))"
EOFDL
RUN chmod +x /usr/local/bin/ghdl

# ── Geant4 10.6.3 ───────────────────────────────────────────────
RUN ghdl Geant4/geant4 v10.6.3 geant4.tar.gz && \
    tar xzf geant4.tar.gz && \
    cd Geant4-geant4-* && mkdir build && cd build && \
    cmake .. \
        -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
        -DCMAKE_CXX_FLAGS="-Wno-error=maybe-uninitialized -Wno-error=stringop-overflow" \
        -DGEANT4_INSTALL_DATA=ON \
        -DGEANT4_USE_OPENGL_X11=ON \
        -DGEANT4_USE_RAYTRACER_X11=ON \
        -DGEANT4_BUILD_MULTITHREADED=ON && \
    make -j4 && make install && \
    cd /tmp/build && rm -rf Geant4-* geant4.tar.gz

# ── ROOT 6.30.06 ────────────────────────────────────────────────
RUN ghdl root-project/root v6-30-06 root.tar.gz && \
    tar xzf root.tar.gz && \
    cd root-root-* && mkdir build && cd build && \
    cmake .. \
        -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
        -DCMAKE_CXX_STANDARD=17 \
        -Droot7=OFF -Dtmva=ON -Deve=ON -Dx11=ON -Dopengl=ON \
        -Dfail-on-missing=ON && \
    make -j4 && make install && \
    cd /tmp/build && rm -rf root-* root.tar.gz

# ── ACTS (ykrsama/xuliang-v30) ──────────────────────────────────
RUN ghdl ykrsama/acts xuliang-v30 acts.tar.gz && \
    tar xzf acts.tar.gz && \
    cd ykrsama-acts-* && mkdir build && cd build && \
    cmake .. \
        -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
        -DCMAKE_CXX_STANDARD=17 \
        -DACTS_BUILD_PLUGIN_JSON=ON && \
    make -j4 && make install && \
    cd /tmp/build && rm -rf ykrsama-acts-* acts.tar.gz

# ── ONNX Runtime ────────────────────────────────────────────────
ARG SKIP_ONNX=0
RUN if [ "${SKIP_ONNX}" = "0" ]; then \
      ghdl microsoft/onnxruntime v1.19.2 onnx.tar.gz && \
      tar xzf onnx.tar.gz && cd onnxruntime-* && \
      ./build.sh --config Release --build_shared_lib --parallel 4 \
          --skip_tests --use_cuda=OFF && \
      cp -r include/onnxruntime ${INSTALL_PREFIX}/include/ && \
      find build/Linux/Release -name 'libonnxruntime*.so*' \
          -exec cp -a {} ${INSTALL_PREFIX}/lib/ \; && \
      cd /tmp/build && rm -rf onnxruntime-* onnx.tar.gz; \
    else echo "ONNX Runtime skipped"; fi

# ── Setup ───────────────────────────────────────────────────────
RUN printf '#!/bin/bash\n\
export DSS_DIR=%s\n\
export PATH=${DSS_DIR}/bin:${PATH}\n\
export LD_LIBRARY_PATH=${DSS_DIR}/lib:${DSS_DIR}/lib64:${LD_LIBRARY_PATH}\n\
source ${DSS_DIR}/bin/geant4.sh\n\
source ${DSS_DIR}/bin/thisroot.sh\n' \
    ${INSTALL_PREFIX} > ${INSTALL_PREFIX}/setup.sh && \
    chmod +x ${INSTALL_PREFIX}/setup.sh && \
    rm -rf /tmp/build

WORKDIR /work
CMD ["/bin/bash", "-c", "source /opt/darkshine/setup.sh && exec /bin/bash"]
