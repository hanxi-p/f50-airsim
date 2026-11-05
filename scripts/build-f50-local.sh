#!/usr/bin/env bash
# Run as root in a disposable Ubuntu 20.04 build VM. Inputs are Git archives.
set -euo pipefail
inputs=${1:?usage: build-f50-local.sh INPUT_DIRECTORY}
inputs=$(realpath "$inputs")
cd "$inputs"
sha256sum --check SHA256SUMS
for path in /build /inputs /linux-reference /audio-reference /recipe /evidence; do
    if [[ -e "$path" ]]; then
        echo "Use a fresh VM or recover the existing build from $path" >&2
        exit 1
    fi
    mkdir "$path"
done
cp zte-git-verified.tar.gz /inputs/zte-b50db5b.tar.gz
tar -xf linux-reference.tar -C /linux-reference
tar -xf audio-reference.tar -C /audio-reference
tar -xf r21-recipe.tar --strip-components=2 -C /recipe
tar -xf reference-kernel.tar.gz -C /build
patch --batch --forward --fuzz=0 -d /audio-reference -p1 < /recipe/guard-reservation.patch
patch --batch --forward --fuzz=0 -d /audio-reference -p1 < /recipe/startup-check.patch
# Replace only the archive-container hash, using the archive from the pinned Git tree.
# The normalized Kconfig and kernel-release guards in the recipe stay active.
git_archive_sha=$(sha256sum /inputs/zte-b50db5b.tar.gz | cut -d ' ' -f1)
sed -i "s/857c5fd717a7f93668be7df87243f733c8c5b1edc66eda03672c982a43a81ef1/$git_archive_sha/" /recipe/build-kernel.sh
export PATH=/usr/lib/llvm-12/bin:$PATH
if [[ $(uname -m) != aarch64 ]]; then
    export CROSS_COMPILE=aarch64-linux-gnu-
fi
export JOBS=${JOBS:-4}
cp SHA256SUMS /evidence/input-SHA256SUMS
clang --version > /evidence/toolchain.txt
ld.lld --version >> /evidence/toolchain.txt
bash /recipe/build-kernel.sh compile 2>&1 | tee /evidence/kernel-build.log
bash /recipe/build-audio.sh 2>&1 | tee /evidence/audio-build.log
cp /build/out-linux/.config /evidence/kernel.config
python3 openwrt-audio-abi.py \
    --kernel-symvers /evidence/openwrt-Module.symvers \
    --audio-symvers /evidence/audio-Module.symvers \
    --references /build/modules --candidates /evidence/audio-modules \
    --report /evidence/abi-report.json
