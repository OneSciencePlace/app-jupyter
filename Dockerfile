FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive

# git and curl are what people expect to have inside a notebook session.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# A .sif is read-only and Apptainer runs as the invoking user, so every path
# Jupyter writes to has to live in /tmp. JUPYTER_RUNTIME_DIR in particular:
# Jupyter puts its connection files and kernel sockets there on every start.
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache \
    MPLCONFIGDIR=/tmp/matplotlib
# The JUPYTER_* paths are NOT set here: entrypoint.sh derives them from TMPDIR
# and the runtime uid, which an ENV cannot do. See the comment there.

# Branch A of the interactive contract: JupyterLab reads ?token= natively, so
# OSP_APP_TOKEN_NAME stays `token` and there is no nginx gate in this image.
# OSP_APP_TOKEN_NAME is deliberately NOT an ENV here. Its value is a parameter
# name, not a secret, but BuildKit's SecretsUsedInArgOrEnv check matches on
# the word TOKEN and warns. web/session-env.sh already defaults it to `token`,
# so the ENV was redundant.
ENV OSP_APP_PORT=8888
EXPOSE 8888

# /etc/passwd group-writable so entrypoint can add an entry for the runtime uid
# when run as `--user "$(id -u):0"`. Harmless otherwise, and read-only under
# Apptainer, which supplies the entry itself.
RUN chmod g=u /etc/passwd /etc/group

COPY web/ /app/web/
COPY entrypoint.sh /app/entrypoint.sh
# Explicit modes. COPY preserves the build context's permissions, so a checkout
# made under a restrictive umask yields 0600/0700 files that the runtime user --
# `docker run --user`, or any user at all under Apptainer -- cannot even read.
# Git only tracks the exec bit, so this is not something the repo can guarantee.
RUN chmod -R a+rX /app && chmod 0755 /app/entrypoint.sh /app/web/session-env.sh

# The notebook root is the caller's working directory: Docker gets it from
# WORKDIR, Apptainer from wherever the user ran the command.
# /data is a mount point. Make it writable by whoever runs the container, so a
# run without a bind mount still works for a non-root user.
RUN mkdir -p /data && chmod 1777 /data

WORKDIR /data

ENTRYPOINT ["/app/entrypoint.sh"]
