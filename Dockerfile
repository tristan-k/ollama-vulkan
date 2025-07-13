FROM --platform=linux/amd64 library/ubuntu:noble as builder

ENV DEBIAN_FRONTEND="noninteractive"

# Please note! You maybe have to adjust the version to the newest available
# otherwise the download of the repository could fail.
ENV VULKAN_VER_BASE="1.4.313"
ENV VULKAN_VER="${VULKAN_VER_BASE}.1"

ENV UBUNTU_VERSION="noble"

ENV GOLANG_VERSION="1.24.3"
ENV GOARCH="amd64"
ENV CGO_ENABLED=1
ENV UPSTREAM_VERSION="0.9.3"
ENV VERSION="${UPSTREAM_VERSION}"
ENV GOFLAGS="'-ldflags=-w -s \"-X=github.com/ollama/ollama/version.Version=$VERSION\" \"-X=github.com/ollama/ollama/server.mode=release\"'"

# Default mirror was very slow
RUN \
    sed -i 's/archive.ubuntu.com/gb.archive.ubuntu.com/g' /etc/apt/sources.list.d/ubuntu.sources

RUN \
    apt-get update && \
    apt-get install -y ca-certificates build-essential ccache cmake wget git curl rsync xz-utils libcap-dev

RUN \
    mkdir -p /usr/local 2>/dev/null || true && \
    curl -s -L https://dl.google.com/go/go${GOLANG_VERSION}.linux-${GOARCH}.tar.gz | tar -xz -C /usr/local && \
    ln -s /usr/local/go/bin/go /usr/local/bin/go && \
    ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt


RUN \
    wget -qO - https://packages.lunarg.com/lunarg-signing-key-pub.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/lunarg-signing-key-pub.gpg && \
    wget -qO /etc/apt/sources.list.d/lunarg-vulkan-${UBUNTU_VERSION}.list https://packages.lunarg.com/vulkan/${VULKAN_VER_BASE}/lunarg-vulkan-${VULKAN_VER_BASE}-${UBUNTU_VERSION}.list && \
    apt update && apt install -y vulkan-sdk

# Last testet ollama-vulkan commit:
# 2d443b3dd660a1fd2760d64538512df93648b4bb
COPY patches/ /tmp/patches/
RUN \
    git clone https://github.com/pufferffish/ollama-vulkan.git "/tmp/ollama-vulkan-git" && \
    cd "/tmp/ollama-vulkan-git" && \
    git checkout 2d443b3dd660a1fd2760d64538512df93648b4bb && git checkout -b ollama_vulkan_stable && \
    git config user.name "Builder" && git config user.email "builder@local" && \
    git remote add ollama_vanilla https://github.com/ollama/ollama.git && \
    git fetch ollama_vanilla --tags && git checkout v${UPSTREAM_VERSION} && git checkout -b ollama_vanilla_stable && \
    git checkout ollama_vulkan_stable && git merge ollama_vanilla_stable --allow-unrelated-histories --no-edit

RUN \
    cd "/tmp/ollama-vulkan-git" && \
    make -f Makefile.sync clean checkout apply-patches sync && \
    for p in \
        /tmp/patches/01-fix-build.patch \
        /tmp/patches/03-fix-ggml_backend_tensor_set.patch \
        /tmp/patches/04-disable-mmap-vulkan.patch \
        /tmp/patches/05-flashattention.patch \
        /tmp/patches/06-GGML_VK_VISIBLE_DEVICES-fix.patch; \
    do patch -p1 < $p || exit 1; done

FROM builder AS cpu-build
RUN \
    cd "/tmp/ollama-vulkan-git" && \
    cmake --fresh --preset CPU && cmake --build --parallel --preset CPU && \
    cmake --install build --component CPU --strip

FROM builder AS vulkan-build
RUN \
    cd "/tmp/ollama-vulkan-git" && \
    cmake --fresh --preset Vulkan && \
    cmake --build --parallel --preset Vulkan && \
    cmake --install build --component Vulkan --strip

FROM builder AS binary-build
RUN \
    cd "/tmp/ollama-vulkan-git" && \
    . scripts/env.sh && \
    mkdir -p dist/bin && \
    go build -trimpath -buildmode=pie -o dist/bin/ollama .


FROM --platform=linux/amd64 library/ubuntu:noble
RUN \
    apt-get update && \
    apt-get install -y ca-certificates libcap2 libvulkan1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
COPY --from=cpu-build /tmp/ollama-vulkan-git/dist/lib/ollama/ /lib/ollama/
COPY --from=vulkan-build /tmp/ollama-vulkan-git/dist/lib/ollama/vulkan/ /lib/ollama/vulkan/
COPY --from=binary-build /tmp/ollama-vulkan-git/dist/bin/ /bin/

RUN find /lib/ollama && find /bin/ollama

EXPOSE 11434
ENV OLLAMA_HOST 0.0.0.0

ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]
