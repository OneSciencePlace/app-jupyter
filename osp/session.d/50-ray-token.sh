# shellcheck shell=bash
# 50-ray-token.sh - Ray: require token authentication, with a token made for
# this session. Sourced by entrypoint.sh at every session start (see README.md
# here).
#
# Why: ray.init() in a notebook starts a local cluster whose control service
# listens on the node's own address, and whose dashboard serves Ray's Jobs API:
# whoever reaches it can submit a job, i.e. run any code in this session. Ray
# before 2.52 has no authentication at all (finish-build.sh refuses it); Ray
# 2.52 to 2.58 has token authentication but leaves it off unless
# RAY_AUTH_MODE=token; Ray 2.59 and later turn it on for local clusters and
# keep the token in ~/.ray/auth_token, so whether it is private depends on
# where the home directory is.
#
# How: a random token, made now, in the 0700 session directory;
# RAY_AUTH_MODE=token (Ray accepts only that exact word) and
# RAY_AUTH_TOKEN_PATH pointing at the file. Clusters this session starts, and
# its own clients, use it; the Jobs API answers 401 and the control service
# refuses anyone without it. Only the file's path goes into the environment.
# A job that sets RAY_AUTH_MODE, RAY_AUTH_TOKEN or RAY_AUTH_TOKEN_PATH itself
# keeps its values.
#
# Nothing to do unless Ray is installed.
if osp_has_module ray; then
    export RAY_AUTH_MODE="${RAY_AUTH_MODE:-token}"
    if [ -z "${RAY_AUTH_TOKEN:-}" ] && [ -z "${RAY_AUTH_TOKEN_PATH:-}" ]; then
        _ray="$OSP_APP_SOCK_DIR/ray"
        mkdir -p "$_ray"
        od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$_ray/auth_token"
        export RAY_AUTH_TOKEN_PATH="$_ray/auth_token"
    fi
    echo "[app] Ray: token authentication ($RAY_AUTH_MODE)"
fi
