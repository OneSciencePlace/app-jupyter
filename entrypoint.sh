#!/bin/bash
# app-jupyter - JupyterLab behind the token gate, like every interactive app:
#
#   $OSP_APP_BIND:$OSP_APP_PORT     nginx gate     <- the session's only TCP listener
#   $OSP_APP_SOCK_DIR/app.sock      JupyterLab, on a Unix socket
#
# The gate checks the session token and is the authentication; Jupyter's own
# token is off and Jupyter never sees OSP_APP_TOKEN. Two processes, so the
# entrypoint stays and supervises them (web/supervise.sh): bash, not sh.
set -eu
umask 077

# Bulk scratch directory. The scheduler usually hands us a TMPDIR pointing at a
# host path like /scratch/$USER/job.12345 -- and Apptainer does not necessarily
# bind it. Inside the container that path may not exist and the root
# filesystem is read-only, so `mkdir -p "$TMPDIR"` would die with "Read-only
# file system". Try the candidates in order and use the first one we can
# actually write to. Under the OSP run profile the app definition sets
# TMPDIR=<job directory>/tmp, which is bound and writable. Never bind a
# scratch parent (/scratch, a Lustre root) to make an inherited TMPDIR work:
# it shows every other job directory of the account to this container.
#
# Only bulk data goes here. Secrets, sockets and session state go in
# $OSP_APP_SOCK_DIR (created by session-env.sh under the private /tmp).
_pick_tmpdir() {
    for _d in "${TMPDIR:-}" /tmp "${HOME:-}"; do
        [ -n "$_d" ] || continue
        mkdir -p "$_d" 2>/dev/null || continue
        [ -w "$_d" ] || continue
        printf '%s' "$_d"
        return 0
    done
    return 1
}
_tmpdir_was="${TMPDIR:-}"
TMPDIR="$(_pick_tmpdir)" || {
    echo "[app] no writable scratch directory (tried TMPDIR, /tmp, HOME)" >&2
    exit 1
}
export TMPDIR
if [ -n "$_tmpdir_was" ] && [ "$_tmpdir_was" != "$TMPDIR" ]; then
    echo "[app] TMPDIR=$_tmpdir_was is not writable in this container; using $TMPDIR" >&2
fi

. /app/web/session-env.sh       # OSP_APP_PORT, OSP_APP_BIND, OSP_APP_TOKEN*, OSP_APP_SOCK_DIR; HOME, XDG_CACHE_HOME
. /app/web/supervise.sh         # installs the cleanup trap before anything starts

APP_SOCK="$OSP_APP_SOCK_DIR/app.sock"
# What the gate's /healthz asks Jupyter for: /api answers 200 once the server
# is up (it returns Jupyter's version and needs no login).
export OSP_APP_HEALTH_PATH="${OSP_APP_HEALTH_PATH:-api}"

# Jupyter's own directories live in the session directory. The runtime
# directory holds the kernel connection files, with the HMAC keys that
# authenticate every message to a kernel, and the kernels' ipc sockets, so it
# must be private to this session and never on the shared storage $TMPDIR
# points at. The session directory is a fresh 0700 directory under the
# private /tmp, so no uid suffix is needed -- and none would help: every
# session of a service account has the same uid. Its path is short
# (/tmp/osp-app-XXXXXXXX/jupyter, 29 characters), well inside the ~107 bytes
# a Unix socket path may have.
JUPYTER_BASE="$OSP_APP_SOCK_DIR/jupyter"
mkdir -p "$JUPYTER_BASE"
export JUPYTER_CONFIG_DIR="${JUPYTER_BASE}/config" \
       JUPYTER_DATA_DIR="${JUPYTER_BASE}/data" \
       JUPYTER_RUNTIME_DIR="${JUPYTER_BASE}/runtime" \
       IPYTHONDIR="${JUPYTER_BASE}/ipython"

# Library caches that may grow go under $TMPDIR, per session, beside the
# XDG_CACHE_HOME that session-env.sh set up -- but only while the image's /tmp
# default is still in effect; a value the job set itself is kept.
_bulk="$TMPDIR/${OSP_APP_SOCK_DIR##*/}"
if [ "${MPLCONFIGDIR:-}" = /tmp/matplotlib ]; then
    export MPLCONFIGDIR="$_bulk/matplotlib"
fi

# JupyterLab on the session's Unix socket (0600, in the 0700 session
# directory), never on TCP. It is the session leader: File > Shut Down is a
# normal log-out and ends the session with status 0. It runs without
# OSP_APP_TOKEN in its environment, so neither it nor its kernels and
# terminals carry the session's secret; only the gate does.
#
# ServerApp.root_dir defaults to the CWD, which is what we want: Apptainer
# starts us in the user's directory and their files are simply there.
osp_spawn leader jupyter jupyter-lab -- env -u OSP_APP_TOKEN jupyter-lab \
    --ServerApp.sock="$APP_SOCK" \
    --ServerApp.sock_mode=0600 \
    --IdentityProvider.token= \
    --ServerApp.allow_root=True \
    --ServerApp.open_browser=False \
    --ServerApp.allow_remote_access=True \
    --ServerApp.trust_xheaders=True \
    --KernelManager.transport=ipc \
    --ServerApp.terminado_settings="{'shell_command': ['/bin/bash']}" \
    "$@"
_jupyter=$OSP_PID

# Do not start the gate until Jupyter is listening, or the first request gets
# a 502. Up to 30 s: a first start on a cold node can be slow.
_i=0
until [ -S "$APP_SOCK" ]; do
    osp_alive "$_jupyter" || { echo "[app] JupyterLab exited during startup" >&2; exit 1; }
    _i=$((_i + 1))
    [ "$_i" -lt 300 ] || { echo "[app] JupyterLab did not start listening" >&2; exit 1; }
    sleep 0.1
done
echo "[app] JupyterLab on unix:$APP_SOCK"

# The gate. token-gate.sh execs nginx, so the registered pid is nginx's.
osp_spawn critical gate nginx -- /app/web/token-gate.sh

osp_supervise

# The gate is the authentication: it lets a request through only with the
# session's token (first request, in the URL) or the cookie it trades it for.
# Behind it, Jupyter's own token is off (--IdentityProvider.token=, and no
# password is set): its socket is reachable only from inside this session, the
# same as noVNC's websockify. Jupyter's XSRF protection stays on.
#
# allow_remote_access lets Jupyter accept requests whose Host header is not
# localhost -- which is every request through the Satellite proxy and the gate.
# Without it Jupyter answers them 403.
#
# allow_root is for `docker run` only. Docker starts us as root unless the
# caller passes --user, and Jupyter refuses to start as uid 0 without this.
# Under Apptainer we are always the invoking user and the flag is a no-op.
#
# KernelManager.transport=ipc puts the kernel's ZMQ channels on Unix sockets
# instead of TCP. Under Docker that is cosmetic -- loopback inside the
# container's own network namespace. Under Apptainer there IS no network
# namespace, so TCP kernel ports would land on the compute node's real
# loopback, reachable by every other session on that node. The sockets are
# made in the runtime directory above, inside the 0700 session directory.
#
# trust_xheaders makes Jupyter believe the gate's X-Forwarded-Proto: https, so
# the websocket URLs it generates come out wss:// rather than ws://.
