# shellcheck shell=bash
# 50-dask-tls.sh - Dask: require mutual TLS, with a certificate made for this
# session. Sourced by entrypoint.sh at every session start (see README.md here).
#
# Why: a dask.distributed cluster started in a notebook -- Client(),
# LocalCluster() -- runs a scheduler and workers on TCP ports. Under Apptainer
# those are on the compute node's own network, and without TLS any process on
# the node that connects to the scheduler can run code in this session's
# workers: no token, no key (plan NEW-19, reproduced).
#
# How: a self-signed certificate and key, made now, in the 0700 session
# directory, and Dask's own configuration variables pointing at them. Dask then
# requires TLS for every connection and accepts only peers holding this
# certificate: clusters this session starts and the clients it connects work as
# usual; nothing outside the session holds the key. Only file paths go into the
# environment. A job that sets these variables itself keeps its values.
#
# Not covered: Dask's dashboard, which LocalCluster starts on 0.0.0.0:8787
# without authentication. It shows tasks and logs, not a way to run code;
# LocalCluster(dashboard_address=None) turns it off.
#
# Nothing to do unless Dask's distributed package is installed.
if osp_has_module distributed; then
    _dask="$OSP_APP_SOCK_DIR/dask"
    mkdir -p "$_dask"
    export DASK_DISTRIBUTED__COMM__REQUIRE_ENCRYPTION="${DASK_DISTRIBUTED__COMM__REQUIRE_ENCRYPTION:-True}"
    if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -days 400 -subj /CN=osp-session \
            -keyout "$_dask/key.pem" -out "$_dask/cert.pem" 2>/dev/null \
       && cat "$_dask/key.pem" "$_dask/cert.pem" > "$_dask/session.pem"; then
        export DASK_DISTRIBUTED__COMM__TLS__CA_FILE="${DASK_DISTRIBUTED__COMM__TLS__CA_FILE:-$_dask/cert.pem}" \
               DASK_DISTRIBUTED__COMM__TLS__SCHEDULER__CERT="${DASK_DISTRIBUTED__COMM__TLS__SCHEDULER__CERT:-$_dask/session.pem}" \
               DASK_DISTRIBUTED__COMM__TLS__WORKER__CERT="${DASK_DISTRIBUTED__COMM__TLS__WORKER__CERT:-$_dask/session.pem}" \
               DASK_DISTRIBUTED__COMM__TLS__CLIENT__CERT="${DASK_DISTRIBUTED__COMM__TLS__CLIENT__CERT:-$_dask/session.pem}"
        echo "[app] Dask: TLS with this session's certificate"
    else
        # Fail closed: with encryption required and no certificate, Dask
        # clusters refuse to start rather than listen without TLS.
        echo "[app] Dask: could not make a certificate; Dask clusters will not start" >&2
    fi
fi
