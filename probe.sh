#!/usr/bin/env bash
# CI 机器探针：识别 CPU 型号/虚拟化/配额，再跑两个短基准，结果可与公开 benchmark 或生产机基线对比。
# 用法：bash probe.sh            （识别 + openssl 基准，约 30 秒）
#       PROBE_COMPILE=1 bash probe.sh   （再加 ripgrep 14.1.1 release 编译计时，约 1–3 分钟）
set -uo pipefail
sec() { printf '\n===== %s =====\n' "$1"; }

sec identity
uname -srm
. /etc/os-release 2>/dev/null && echo "os: $PRETTY_NAME"
echo "nproc: $(nproc)"
lscpu 2>/dev/null | grep -E '^(Vendor ID|Model name|Stepping|Thread|Core|Socket|CPU\(s\)|BogoMIPS|Flags|L[123])' || true
grep -E 'CPU (implementer|part|variant|revision)' /proc/cpuinfo | sort | uniq -c
# MIDR 解码：只列常见服务器核；未知的照原样输出，拿 implementer/part 查表即可。
impl=$(awk -F: '/CPU implementer/{gsub(/ /,"",$2);print $2;exit}' /proc/cpuinfo)
part=$(awk -F: '/CPU part/{gsub(/ /,"",$2);print $2;exit}' /proc/cpuinfo)
case "$impl:$part" in
  0x41:0xd0c) core="Arm Neoverse-N1 (Ampere Altra / Graviton2 / OCI A1)";;
  0x41:0xd40) core="Arm Neoverse-V1 (Graviton3)";;
  0x41:0xd49) core="Arm Neoverse-N2 (Azure Cobalt 100 / Yitian 710)";;
  0x41:0xd4f) core="Arm Neoverse-V2 (Graviton4 / Grace / Axion)";;
  0x41:0xd8e) core="Arm Neoverse-N3";;
  0x41:0xd84) core="Arm Neoverse-V3";;
  0xc0:0xac3|0xc0:0xac4|0xc0:0xac5) core="AmpereOne family";;
  0x48:0xd01) core="HiSilicon TaiShan v110 (Kunpeng 920)";;
  0x48:0xd02) core="HiSilicon TaiShan v120 (Kunpeng 920 新款)";;
  :) core="(no MIDR in /proc/cpuinfo — x86 或被隐藏)";;
  *) core="unknown MIDR $impl:$part";;
esac
echo "decoded core: $core"
grep -m1 'model name' /proc/cpuinfo || true   # x86 才有

sec virtualization
command -v systemd-detect-virt >/dev/null && echo "virt: $(systemd-detect-virt 2>/dev/null; systemd-detect-virt -c 2>/dev/null)"
for f in sys_vendor product_name bios_vendor; do printf '%s: %s\n' "$f" "$(cat /sys/devices/virtual/dmi/id/$f 2>/dev/null)"; done
# 真正的“软件模拟 ARM”（qemu-user/TCG）通常 BogoMIPS 异常、缺 cpuid/atomics 等标志，且下面的基准会慢一个数量级。
ls /proc/sys/fs/binfmt_misc 2>/dev/null | grep -i qemu && echo "binfmt qemu handlers present"

sec quotas
cg=/sys/fs/cgroup$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup 2>/dev/null)
echo "cgroup: $cg"
while [[ -n "$cg" && "$cg" != /sys/fs ]]; do   # 从自己的 cgroup 往上找生效的限额
  for f in cpu.max memory.max; do [[ -r $cg/$f ]] && [[ "$(cat $cg/$f)" != max* ]] && echo "$f @ ${cg#/sys/fs/cgroup}: $(cat $cg/$f)"; done
  cg=${cg%/*}
done
free -g | head -2
df -h / "$HOME" 2>/dev/null | sort -u
for f in cpuinfo_max_freq scaling_cur_freq; do v=$(cat /sys/devices/system/cpu/cpu0/cpufreq/$f 2>/dev/null) && echo "$f: $v kHz"; done

sec "network: 下载速度/连接延迟（限时 20 秒）"
dl() { # 名称 URL
  curl -s -o /dev/null -m 20 -L -w "$1: %{speed_download} B/s  connect %{time_connect}s  total %{time_total}s  http %{http_code}\n" "$2" || echo "$1: FAILED"
}
dl "rust-lang CDN (大文件)" https://static.rust-lang.org/dist/rust-1.98.1-aarch64-unknown-linux-gnu.tar.xz
dl "crates.io (ripgrep crate)" https://static.crates.io/crates/ripgrep/ripgrep-14.1.1.crate
dl "GitHub release asset" https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-aarch64-unknown-linux-gnu.tar.gz
dl "B2 us-west-004 (仅连接)" https://s3.us-west-004.backblazeb2.com/
dl "Singapore prod 方向 (OCI 对象存储端点)" https://objectstorage.ap-singapore-1.oraclecloud.com/

sec "benchmark: openssl sha256 (单核 / 全核)"
steal0=$(awk '/^cpu /{print $9}' /proc/stat)
openssl version
openssl speed -seconds 3 sha256 2>/dev/null | tail -1 | sed 's/^/1 core:   /'
openssl speed -seconds 3 -multi "$(nproc)" sha256 2>/dev/null | tail -1 | sed "s/^/$(nproc) cores: /"
steal1=$(awk '/^cpu /{print $9}' /proc/stat)
echo "steal ticks during benchmark: $((steal1 - steal0))   (明显 >0 说明宿主超卖)"

if [[ "${PROBE_COMPILE:-0}" == 1 ]]; then
  sec "benchmark: cargo build --release ripgrep 14.1.1"
  work=$(mktemp -d)
  if ! command -v cargo >/dev/null; then
    curl -sSf https://sh.rustup.rs | sh -s -- -y -q --profile minimal --default-toolchain 1.98.1 >/dev/null
    . "$HOME/.cargo/env"
  fi
  rustc --version
  curl -sSfL https://static.crates.io/crates/ripgrep/ripgrep-14.1.1.crate | tar xz -C "$work"
  cd "$work/ripgrep-14.1.1"
  cargo fetch --locked -q
  export CARGO_INCREMENTAL=0 RUSTC_WRAPPER= CARGO_TARGET_DIR="$work/target"
  jobs=${PROBE_JOBS:-$(nproc)}
  s=$(date +%s%N); cargo build --release --locked --offline -q -j "$jobs"; e=$(date +%s%N)
  echo "ripgrep release build, -j $jobs: $(( (e - s) / 1000000 )) ms"
  rm -rf "$work"
fi
