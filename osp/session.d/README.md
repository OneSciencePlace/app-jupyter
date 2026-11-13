# Session hooks

Small bash files that the entrypoint runs at the start of every session,
before JupyterLab starts. Whatever a hook exports reaches JupyterLab, its
kernels and its terminals. They live in `/app/osp/session.d/` and run in name
order.

## Why there are hooks

Some Python packages start servers when a notebook calls them: Dask's
`Client()`, Ray's `ray.init()`. Under Apptainer a session has no network of its
own, so those servers listen on the compute node's network, where every other
session -- and, for some of them, every other host -- can reach them. If the
server has no login, anyone who connects can run code in your session.

Some of these packages can require a login through their own settings alone.
A hook makes a secret for the session, keeps it in the session's private
directory, and sets the package's settings to use it. The notebook does not
change: `Client()` and `ray.init()` work as before, and nobody outside the
session holds the secret.

This image ships two such hooks. Each does nothing unless its package is
installed, so they cost nothing in images without it.

| Hook | Package | What it sets up |
|---|---|---|
| `50-dask-tls.sh` | Dask (`distributed`) | mutual TLS with a certificate made for the session |
| `50-ray-token.sh` | Ray | token authentication with a token made for the session; Ray older than 2.52 is refused at build |

Not covered: Dask's dashboard (`0.0.0.0:8787`, no login; it shows tasks and
logs, and `LocalCluster(dashboard_address=None)` turns it off). Servers that
can only be given a login where they are started -- Bokeh or Panel servers,
TensorBoard, Streamlit, Gradio, PyTorch's distributed store -- are not
something a hook can fix; an image that ships one says in its README how it
is meant to be used safely.

## Adding your own

In an image built on app-jupyter, put hooks in a `session.d/` folder beside
`requirements.txt`. `install.sh` adds them to the image; it refuses a name the
image already has, and anything that is not valid bash. Name them
`NN-what.sh`: `NN` sets the order (the image's own use `50`; use `60` or more
to run after them).

A hook must:

- **do nothing when its package is absent.** Start with
  `if osp_has_module <python module>; then ... fi` (`osp_has_module` is
  defined by the entrypoint).
- **keep secrets in `$OSP_APP_SOCK_DIR`.** That is the session's private
  directory (`0700`, files `0600`), under the container's private `/tmp`.
  Never write a secret under `$TMPDIR` or the working directory: those are the
  job directory, on shared storage.
- **put only paths and switches in the environment,** never a secret itself:
  kernels and terminals inherit the environment, and so does anything a user
  runs.
- **keep what the job set.** Use `"${NAME:-default}"`, so an app definition
  can still choose otherwise.
- **fail closed.** If the secret cannot be made, leave the package unable to
  start its server rather than starting it open.
- **be quick and quiet.** One line on stdout saying what it set up, nothing
  secret, ever.

It is sourced by bash with `set -eu` and `umask 077`: an unset variable or a
failing command stops the session from starting, which is the safe outcome.
Names starting with `_` are free for its own use.

## Worked example: `50-dask-tls.sh`

```bash
if osp_has_module distributed; then                 # 1. only if Dask is installed
    _dask="$OSP_APP_SOCK_DIR/dask"                  # 2. secrets in the private directory
    mkdir -p "$_dask"
    export DASK_DISTRIBUTED__COMM__REQUIRE_ENCRYPTION="${DASK_DISTRIBUTED__COMM__REQUIRE_ENCRYPTION:-True}"
    if openssl req -x509 ... -keyout "$_dask/key.pem" -out "$_dask/cert.pem" ...; then
        export DASK_DISTRIBUTED__COMM__TLS__CA_FILE="${...:-$_dask/cert.pem}" ...   # 3. paths only
        echo "[app] Dask: TLS with this session's certificate"                     # 4. one line
    else
        echo "[app] Dask: could not make a certificate; ..." >&2                   # 5. fail closed:
    fi                                                                              #    TLS stays required
fi
```

1. Dask's `distributed` package is what starts servers; plain `dask` does not.
2. The certificate and its key are made fresh every session, in
   `$OSP_APP_SOCK_DIR/dask`.
3. Dask reads `DASK_*` variables as its configuration. Requiring encryption
   and naming the certificate files is all it takes: every scheduler, worker
   and client in the session uses them, and a peer without the key is refused.
4. The job log says the hook ran.
5. If `openssl` fails, encryption is still required but there is no
   certificate, so Dask refuses to start a cluster at all.

`50-ray-token.sh` follows the same steps with a random token
(`RAY_AUTH_MODE=token`, `RAY_AUTH_TOKEN_PATH`).

To find out whether another package can be handled this way, look in its
documentation for authentication or TLS that is switched on by environment
variables or a configuration file, and that works for a cluster started by
the notebook itself. Then test it: a client started with the session's
environment works, and one started without it is refused.
