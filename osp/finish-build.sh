#!/bin/sh
# osp/finish-build.sh - the last RUN line of app-jupyter's Dockerfile and of
# every image built FROM it:
#
#   RUN /app/osp/finish-build.sh
#
# Whatever the earlier lines installed, it puts back the hardening those
# packages can undo, then checks the image, and fails the build -- not a
# session on a compute node -- naming what is wrong:
#
#   1. debugpy removed (any package that depends on ipykernel brings it back;
#      with it, JupyterLab's debugger opens an unauthenticated TCP port on the
#      node's loopback), and ipykernel finds no debugger;
#   2. the Jupyter server, kernel and transport at the versions app-jupyter
#      was built with (/app/osp/constraints.txt);
#   3. Jupyter Server can listen on a Unix socket (--ServerApp.sock);
#   4. pip's dependency check passes (debugpy's absence aside);
#   5. what the session files in /app/web need (the kit's check-deps.sh), and
#      openssl, which makes each session's Dask certificate;
#   6. no setuid or setgid files (S-7): /etc/passwd is group-writable in this
#      image, and under Docker without no-new-privileges a setuid program
#      plus a writable passwd is a way to root inside the container.
set -eu

if [ "$(id -u)" != 0 ]; then
    echo "finish-build.sh: must run as root. Do not put a USER line before it." >&2
    exit 1
fi

echo "[finish] 1. debugpy"
if pip show -q debugpy >/dev/null 2>&1; then
    PIP_ROOT_USER_ACTION=ignore pip uninstall -y -q debugpy
    echo "[finish]    removed (ipykernel's dependency; it is not needed)"
fi

echo "[finish] 2. Jupyter versions"
python3 /app/osp/jupyter_pins.py check /app/osp/constraints.txt

echo "[finish] 3. Jupyter Server on a Unix socket"
jupyter-lab --help-all 2>/dev/null | grep -q -- '--ServerApp.sock=' \
    || { echo "finish-build.sh: Jupyter Server has no --ServerApp.sock" >&2; exit 1; }

echo "[finish] 4. pip check"
# ipykernel declares debugpy but imports it only if present (step 1).
_broken=$(PIP_DISABLE_PIP_VERSION_CHECK=1 pip check 2>&1 \
    | grep -v -e '^No broken requirements found' \
              -e '^ipykernel [^ ]* requires debugpy, which is not installed\.$' || true)
if [ -n "$_broken" ]; then
    printf '%s\n' "$_broken" >&2
    echo "finish-build.sh: installed packages need versions that are not installed (above)" >&2
    exit 1
fi

echo "[finish] 5. session files and tools"
/app/web/check-deps.sh
command -v openssl >/dev/null || { echo "finish-build.sh: openssl is missing" >&2; exit 1; }

echo "[finish] 6. setuid and setgid bits"
find / -xdev -type f -perm /6000 -exec chmod a-s {} + 2>/dev/null || true
_left=$(find / -xdev -type f -perm /6000 2>/dev/null | head -5)
if [ -n "$_left" ]; then
    printf '%s\n' "$_left" >&2
    echo "finish-build.sh: setuid/setgid files remain (above)" >&2
    exit 1
fi

echo "[finish] ok"
