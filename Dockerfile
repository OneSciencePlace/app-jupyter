# The shared session files (web/: the session contract, the token gate, the
# supervisor) come from app-template's kit image rather than a copy kept in
# this repo: a fix to them reaches this image by bumping this line.
FROM ghcr.io/onescienceplace/app-kit:1.1.0 AS kit

FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive

# git and curl are what people expect to have inside a notebook session.
#
# nginx and gettext-base (envsubst) are the token gate's; bash is the
# entrypoint's shell (web/supervise.sh needs `wait -n`). Debian has no
# nginx-light: its nginx package is the small build.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git \
        nginx gettext-base bash \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# No debugpy, so no JupyterLab debugger. Once a user turns the debugger on,
# ipykernel starts debugpy listening on a TCP port on the node's loopback, and
# it keeps listening after the debugger is turned off again. Any process on the
# node can then attach to that kernel without a token -- pause it, read its
# stack and variables -- because loopback is shared between sessions under
# Apptainer. Without debugpy, ipykernel reports no debugger and JupyterLab
# hides the button.
RUN pip uninstall -y debugpy \
    && python -c "import ipykernel.debugger as d; assert not d._is_debugpy_available, 'debugpy is back'"

# Fail the build, not the session, if Jupyter Server cannot listen on a Unix
# socket. (What the gate and the supervisor need is checked by the kit's
# check-deps.sh, once web/ is in place below.)
RUN jupyter-lab --help-all 2>/dev/null | grep -q -- '--ServerApp.sock=' \
        || { echo "Jupyter Server has no ServerApp.sock" >&2; exit 1; }

# A .sif is read-only and Apptainer runs as the invoking user, so every path
# Jupyter and its libraries write to has to be somewhere writable. These are
# the image's fallbacks, in /tmp.
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache \
    MPLCONFIGDIR=/tmp/matplotlib
# The JUPYTER_* paths are NOT set here: entrypoint.sh puts them in the
# session's private directory, which only exists at run time. HOME and
# XDG_CACHE_HOME, and the other caches, are moved per session at run time while
# these /tmp defaults are still in effect (web/session-env.sh, entrypoint.sh).

# JupyterLab listens on a Unix socket in the session directory; the nginx gate
# owns OSP_APP_PORT and checks the session token. OSP_APP_TOKEN_NAME stays
# `token`, the gate's default.
# OSP_APP_TOKEN_NAME is deliberately NOT an ENV here. Its value is a parameter
# name, not a secret, but BuildKit's SecretsUsedInArgOrEnv check matches on
# the word TOKEN and warns. web/session-env.sh already defaults it to `token`,
# so the ENV was redundant. The gate binds $OSP_APP_BIND, 127.0.0.1 by
# default; a local `docker run -p` needs -e OSP_APP_BIND=0.0.0.0.
ENV OSP_APP_PORT=8888
EXPOSE 8888

# /etc/passwd group-writable so entrypoint can add an entry for the runtime uid
# when run as `--user "$(id -u):0"`. Harmless otherwise, and read-only under
# Apptainer, which supplies the entry itself.
RUN chmod g=u /etc/passwd /etc/group

COPY --from=kit /app/web/ /app/web/
RUN /app/web/check-deps.sh
COPY entrypoint.sh /app/entrypoint.sh
# Explicit modes. COPY preserves the build context's permissions, so a checkout
# made under a restrictive umask yields 0600/0700 files that the runtime user --
# `docker run --user`, or any user at all under Apptainer -- cannot even read.
# Git only tracks the exec bit, so this is not something the repo can guarantee.
# (The kit's files arrive with their modes set.)
RUN chmod -R a+rX /app && chmod 0755 /app/entrypoint.sh

# The notebook root is the caller's working directory: Docker gets it from
# WORKDIR, Apptainer from wherever the user ran the command.
# /data is a mount point. Make it writable by whoever runs the container, so a
# run without a bind mount still works for a non-root user.
RUN mkdir -p /data && chmod 1777 /data

WORKDIR /data

ENTRYPOINT ["/app/entrypoint.sh"]
