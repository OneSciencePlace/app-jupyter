#!/bin/sh
# osp/install.sh <dir> - install an image's own packages and session hooks on
# top of app-jupyter, at build time, as root. In an image built FROM app-jupyter:
#
#   COPY . /tmp/osp/
#   RUN /app/osp/install.sh /tmp/osp
#   RUN /app/osp/finish-build.sh          # always the last RUN line
#
# <dir>/apt.txt           system packages, one or more per line: Debian names,
#                         as the image is python:3.14-slim (Debian 13).
#                         Only for system libraries and tools: Python packages
#                         installed with apt would land in the OS's Python, not
#                         the one JupyterLab and its kernels use.
# <dir>/requirements.txt  Python packages, in pip's requirements format.
# <dir>/session.d/*.sh    session hooks, added to /app/osp/session.d/: sourced
#                         by the entrypoint at every session start
#                         (/app/osp/session.d/README.md). A hook may not
#                         replace one already in the image.
#
# All three are optional; '#' starts a comment in the two lists. pip installs under the constraints
# in /app/osp/constraints.txt, which hold JupyterLab, Jupyter Server, the
# kernel and their plumbing at the versions this image was built and validated
# with: a package that needs other versions of them fails the build here, with
# pip's explanation, instead of quietly changing the server.
#
# Everything is installed at build time. Nothing can be installed in a running
# session: the .sif is read-only.
set -eu

dir=${1:?usage: install.sh <directory holding apt.txt and/or requirements.txt>}
constraints=/app/osp/constraints.txt

if [ "$(id -u)" != 0 ]; then
    echo "install.sh: must run as root. Do not put a USER line before it." >&2
    exit 1
fi
[ -d "$dir" ] || { echo "install.sh: no directory $dir" >&2; exit 1; }

# --- system packages ---------------------------------------------------------
if [ -f "$dir/apt.txt" ]; then
    pkgs=$(sed -e 's/#.*//' "$dir/apt.txt" | tr -s ' \t\r' '\n\n\n' | sed '/^$/d')
    if [ -n "$pkgs" ]; then
        for p in $pkgs; do
            case $p in
                -*|*[!a-z0-9.+:=~-]*)
                    echo "install.sh: apt.txt: '$p' is not a Debian package name" >&2
                    exit 1 ;;
            esac
        done
        echo "[install] apt.txt:" $pkgs
        apt-get update
        # shellcheck disable=SC2086  # one word per package, checked above
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkgs
        rm -rf /var/lib/apt/lists/*
    fi
fi

# --- Python packages ---------------------------------------------------------
if [ -f "$dir/requirements.txt" ] && sed -e 's/#.*//' "$dir/requirements.txt" | grep -q '[^[:space:]]'; then
    echo "[install] requirements.txt"
    if ! PIP_ROOT_USER_ACTION=ignore PIP_DISABLE_PIP_VERSION_CHECK=1 \
            pip install --no-cache-dir -c "$constraints" -r "$dir/requirements.txt"; then
        cat >&2 <<MSG

install.sh: pip could not install requirements.txt (its reasons are above).
If it names jupyterlab, jupyter-server, ipykernel, tornado, pyzmq or another
package in $constraints: one of your packages needs a different
version of the Jupyter software than this image provides. Pick a version of
your package that accepts these, or ask for an app-jupyter release with the
newer Jupyter.
MSG
        exit 1
    fi
fi
# --- session hooks -----------------------------------------------------------
if [ -d "$dir/session.d" ]; then
    for h in "$dir"/session.d/*.sh; do
        [ -f "$h" ] || continue
        name=${h##*/}
        case $name in
            *[!A-Za-z0-9._-]*)
                echo "install.sh: session.d/$name: use letters, digits, '.', '_' and '-' in hook names" >&2
                exit 1 ;;
        esac
        if [ -e "/app/osp/session.d/$name" ]; then
            echo "install.sh: session.d/$name: the image already has a hook of that name; choose another" >&2
            exit 1
        fi
        bash -n "$h" || { echo "install.sh: session.d/$name: not valid bash (above)" >&2; exit 1; }
        install -m 0644 "$h" "/app/osp/session.d/$name"
        echo "[install] session hook $name"
    done
fi
echo "[install] done"
