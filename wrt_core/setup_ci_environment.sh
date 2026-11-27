#!/usr/bin/env bash
set -euo pipefail

source /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_CODENAME:-} != noble || $(dpkg --print-architecture) != amd64 ]]; then
    echo "CI build setup requires Ubuntu 24.04 (amd64)." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# GitHub-hosted ubuntu-24.04 images ship third-party apt repositories
# (Microsoft prod, Azure CLI, Google Cloud, dotnet). They are not needed for
# the build and occasionally answer 403, which aborts "apt-get update" with
# exit code 100 and kills the whole job. Disable them before touching apt.
for src in /etc/apt/sources.list.d/*microsoft* /etc/apt/sources.list.d/*azure* \
           /etc/apt/sources.list.d/*google* /etc/apt/sources.list.d/*dotnet*; do
    [ -e "$src" ] || continue
    mv -f "$src" "$src.disabled" 2>/dev/null || true
    echo "Disabled third-party apt source: $src"
done

# Retry transient mirror/PPA errors instead of failing the build.
printf 'Acquire::Retries "5";\n' > /etc/apt/apt.conf.d/99-wrt-ci-retries
printf 'APT::Install-Recommends "false";\n' > /etc/apt/apt.conf.d/99-wrt-ci

if ! command -v curl >/dev/null || ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q 'install ok installed'; then
    apt-get update -y
    apt-get install -y ca-certificates curl
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 \
    https://build-scripts.immortalwrt.org/init_build_environment.sh \
    -o "$tmp/init.sh"

sed -i -E '/^[[:blank:]]*apt full-upgrade -y /d' "$tmp/init.sh"

TMPDIR="$tmp" bash -e "$tmp/init.sh"
apt-get install -y dos2unix libfuse-dev
for tool in gcc g++ clang go node yarn gh ccache upx padjffs2 po2lmo; do
    command -v "$tool" >/dev/null || { echo "Missing WRT build tool: $tool" >&2; exit 1; }
done
apt-get clean
