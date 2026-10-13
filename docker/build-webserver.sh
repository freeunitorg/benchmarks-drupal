#!/bin/sh
# Build one webserver from a pinned upstream tarball, so nginx, Angie and
# FreeNginx are compared as the same kind of artefact: same flags, same
# toolchain, same optimisation level.  The distro's nginx package stays as it
# is (the published nginx numbers come from it); this script exists for the
# fork comparison, where a package build on one side and a source build on the
# other would be a confound.
#
#   build-webserver.sh NAME URL SHA256 PREFIX CONFIGURE_ARGS...
#
# The sha256 is pinned in the Dockerfile next to the URL.  Upstream publishes
# signatures, not checksums, for both Angie and FreeNginx, so the value here is
# the one the build actually fetched and is recorded in the image label.
set -eu

name=$1
url=$2
sha=$3
prefix=$4
shift 4

src="/tmp/$name.tar.gz"

echo "fetching $url"
curl -fsSL --retry 5 --retry-delay 2 -o "$src" "$url"

echo "$sha  $src" | sha256sum -c -

mkdir -p "/tmp/$name"
tar -xzf "$src" -C "/tmp/$name" --strip-components=1

cd "/tmp/$name"
./configure --prefix="$prefix" "$@"
make -j"$(nproc)"
make install

rm -rf "/tmp/$name" "$src"

# Fail the layer rather than the first request if the binary cannot run.
"$prefix/sbin/$name" -V 2>&1 | head -n 2
