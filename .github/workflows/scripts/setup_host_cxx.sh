#!/usr/bin/env bash
# Supply a native C++23 compiler; the BPF-only clang cannot emit host objects.
set -euo pipefail
prefix=${1:?output directory required}
if (( EUID != 0 )); then exec sudo -n bash "$0" "$prefix"; fi
mkdir -p "$prefix"
exec 9>"$prefix/setup.lock"
flock 9
if test -f "$prefix/complete" && test -x "$prefix/bin/make"; then exit 0; fi
. /etc/os-release
case "$ID:$VERSION_CODENAME" in
    debian:bullseye|debian:bookworm|debian:trixie|ubuntu:jammy|ubuntu:noble) ;;
    *) echo "Unsupported native compiler bootstrap OS: $ID:$VERSION_CODENAME" >&2; exit 2 ;;
esac
if ! command -v clang++-20 >/dev/null || ! test -d /usr/lib/llvm-20/include/c++/v1; then
    mkdir -p /etc/apt/keyrings
    curl --fail --silent --show-error --location --retry 4 --retry-all-errors \
        https://apt.llvm.org/llvm-snapshot.gpg.key -o /etc/apt/keyrings/agw-llvm.asc
    printf 'deb [signed-by=/etc/apt/keyrings/agw-llvm.asc] https://apt.llvm.org/%s/ llvm-toolchain-%s-20 main\n' \
        "$VERSION_CODENAME" "$VERSION_CODENAME" > /etc/apt/sources.list.d/agw-llvm20.list
    apt-get -o Acquire::Retries=4 update
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=4 install -y --no-install-recommends \
        clang-20 libc++-20-dev libc++abi-20-dev
fi
mkdir -p "$prefix/bin" "$prefix/libexec" "$prefix/lib" "$prefix/include"
cp -L /usr/lib/llvm-20/bin/clang "$prefix/libexec/clang"
cp -a /usr/lib/llvm-20/include/c++ "$prefix/include/"
cp -a /usr/lib/llvm-20/lib/clang/20 "$prefix/resource"
# ldd lists the transitive dependency closure. Keep libc and the loader native.
python3 - "$prefix" <<'PY'
from pathlib import Path
import re,shutil,subprocess,sys
p=Path(sys.argv[1]); objects=[Path('/usr/lib/llvm-20/bin/clang')]
objects.extend(Path('/usr/lib/llvm-20/lib').glob('libc++*.so*'))
objects.extend(Path('/usr/lib/llvm-20/lib').glob('libunwind*.so*'))
for obj in objects:
 if obj.name!='clang':shutil.copy2(obj.resolve(),p/'lib'/obj.name)
 proc=subprocess.run(['ldd',str(obj.resolve())],capture_output=True,text=True)
 for name,src in re.findall(r'\s+(\S+) => (/\S+)',proc.stdout):
  if name in {'libc.so.6','libm.so.6','libpthread.so.0','libdl.so.2','librt.so.1'}:continue
  shutil.copy2(Path(src).resolve(),p/'lib'/name)
PY
cat > "$prefix/bin/cc" <<'EOF'
#!/bin/sh
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export LD_LIBRARY_PATH="$root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$root/libexec/clang" --target=x86_64-pc-linux-gnu -resource-dir="$root/resource" "$@"
EOF
cat > "$prefix/bin/cxx" <<'EOF'
#!/bin/sh
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export LD_LIBRARY_PATH="$root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBRARY_PATH="$root/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
exec "$root/libexec/clang" --driver-mode=g++ --target=x86_64-pc-linux-gnu -resource-dir="$root/resource" -stdlib=libc++ -isystem "$root/include/c++/v1" "$@"
EOF
chmod +x "$prefix/bin/cc" "$prefix/bin/cxx"
printf '#include <expected>\nint main(){std::expected<int,int> result=0;return *result;}\n' > "$prefix/probe.cc"
"$prefix/bin/cxx" -std=c++23 "$prefix/probe.cc" -Wl,-rpath,"$prefix/lib" -o "$prefix/probe"
"$prefix/probe"
# GNU Make 4.4 supplies a FIFO jobserver that modern Ninja can share.
make_tmp=$(mktemp -d)
trap 'rm -rf -- "$make_tmp"' EXIT
curl --fail --silent --show-error --location --retry 4 --retry-all-errors \
    https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz -o "$make_tmp/make.tar.gz"
printf 'dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3  %s\n' "$make_tmp/make.tar.gz" | sha256sum -c -
tar -xzf "$make_tmp/make.tar.gz" -C "$make_tmp"
(cd "$make_tmp/make-4.4.1"; ./configure --prefix="$prefix" --disable-nls; make -j4; make install)
"$prefix/bin/make" --version | head -1 > "$prefix/make-version.txt"
dpkg-query -W -f='${Package}\t${Version}\n' clang-20 libllvm20 libclang-cpp20 libc++-20-dev libc++abi-20-dev > "$prefix/packages.tsv"
(cd "$prefix"; find bin libexec lib include resource -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
printf 'native-x86_64-clang20-libcxx20\n' > "$prefix/complete"
