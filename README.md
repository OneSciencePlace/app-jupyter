# app-jupyter

JupyterLab as an interactive `app-*` container, behind the token gate like
every interactive app: the gate is the session's one TCP listener and checks
its token; JupyterLab listens on a Unix socket in the session's private
directory.

```
browser ──https──▶ Satellite proxy ──ssh tunnel──▶ $OSP_APP_BIND:$OSP_APP_PORT   nginx gate
                                                    (127.0.0.1 by default)       │ cookie / 403
                                                                                 ▼
                                                  $OSP_APP_SOCK_DIR/app.sock     jupyter lab
```

## Run it

The token is never put on a command line: `ps` shows command lines to every
user on a node. Pass it through the environment.

```bash
export OSP_APP_TOKEN=$(openssl rand -hex 32)

# Docker (local). -e OSP_APP_TOKEN with no "=value" copies it from your
# environment. OSP_APP_BIND=0.0.0.0 because `-p` cannot reach a container's
# loopback; the host side is still published on 127.0.0.1 only.
docker run --rm --user "$(id -u):$(id -g)" \
  -p 127.0.0.1:8888:8888 -v "$PWD:/data" \
  -e OSP_APP_PORT=8888 -e OSP_APP_BIND=0.0.0.0 -e OSP_APP_TOKEN \
  ghcr.io/onescienceplace/app-jupyter:latest

# Apptainer, under the OSP interactive run profile.
# APPTAINERENV_<NAME> reaches the container as <NAME>, even with --cleanenv
# (SingularityCE: SINGULARITYENV_<NAME>).
apptainer pull oras://ghcr.io/onescienceplace/app-jupyter-sif:latest   # production pins <version>@sha256:<digest>
mkdir -p tmp
export APPTAINERENV_OSP_APP_TOKEN="$OSP_APP_TOKEN"
apptainer run \
  --contain --pid --ipc --cleanenv --no-mount bind-paths,cwd \
  --pwd "$PWD" --bind "$PWD:$PWD" \
  --env OSP_APP_PORT=8888 --env TMPDIR="$PWD/tmp" \
  app-jupyter-sif_latest.sif
```

Then open `http://127.0.0.1:8888/?token=<the token>` (add an
`ssh -L 8888:127.0.0.1:8888 <host>` forward first if it runs elsewhere).
Through the portal the link is
`https://<session-label>.<sat-id>.sat.<domain>/?token=<token>`, handed out by
the launcher once the gate's `/healthz` answers (it asks JupyterLab for
`/api`).

The container prints its port on startup, and the entry path without the
token when the launcher supplied it. JupyterLab never sees the token, so its
own banner cannot print it.

| Variable | Default | Meaning |
|---|---|---|
| `OSP_APP_PORT` | `8888` | the one TCP port, served by the gate |
| `OSP_APP_BIND` | `127.0.0.1` | the address it binds; `0.0.0.0` only inside a Docker job's own network, or for local `docker run -p` |
| `OSP_APP_TOKEN` | generated | per-session secret, checked by the gate |
| `OSP_APP_TOKEN_NAME` | `token` | the query parameter (and cookie) it arrives in |

## Why it sits behind the gate

JupyterLab has its own `?token=` login, and this image used to rely on it,
binding a TCP port itself. It now sits behind the same nginx gate as every
other interactive app, for three reasons:

- **One shape for every interactive app.** The same single, authenticated TCP
  listener, the same `/healthz` for the launcher (the gate asks JupyterLab for
  `/api`), the same validation, the same access log that never records the
  token.
- **No TCP listener of Jupyter's.** JupyterLab listens on
  `$OSP_APP_SOCK_DIR/app.sock` (`0600`, in the session's `0700` directory),
  reachable only from inside the session.
- **The token stays with the gate.** JupyterLab runs with its own token off
  and without `OSP_APP_TOKEN` in its environment, so neither it nor its
  kernels and terminals hold the session's secret. Its XSRF protection stays
  on.

JupyterLab is the session leader under `web/supervise.sh`: **File > Shut
Down** is a normal log-out and ends the session with status 0; JupyterLab or
the gate dying ends it with status 1.

Two settings matter for running behind the Satellite proxy and the gate:
`--ServerApp.trust_xheaders`, because TLS is terminated upstream and without it
Jupyter builds `ws://` websocket URLs on an `https://` page that the browser
refuses; and `--ServerApp.allow_remote_access`, because Jupyter otherwise
rejects every request whose `Host` header is not localhost — which is every
request through the proxy.

## Kernels, the session directory and scratch paths

The token reaches the container through the environment, never as a command
line argument (`/proc/<pid>/cmdline` is world-readable), and only the gate
keeps it: JupyterLab is started without it.

Kernels run over **Unix sockets, not TCP** (`--KernelManager.transport=ipc`).
Under Docker that would be cosmetic — loopback inside the container's own
network namespace — but Apptainer has no network namespace, so TCP kernel ports
would land on the compute node's real loopback, reachable by every other
session there.

`JUPYTER_CONFIG_DIR`, `JUPYTER_DATA_DIR`, `JUPYTER_RUNTIME_DIR` and
`IPYTHONDIR` live in the session's private directory,
`$OSP_APP_SOCK_DIR/jupyter/…` (a fresh `0700` directory under the private
`/tmp`). The runtime directory holds the kernel connection files, with the
keys that authenticate every message to a kernel, and the kernel sockets, so
it must never be on the shared storage `$TMPDIR` points at. A uid suffix would
not protect it: under a service account every session has the same uid.

One consequence: the notebook-signing key is regenerated every session, so
notebook *trust* does not persist and saved HTML/JS outputs need a re-run to
render.

**No debugger.** The image removes `debugpy`, so JupyterLab shows no debugger.
With it, turning the debugger on starts a debug server on a TCP port on the
node's loopback, and it keeps listening after the debugger is turned off; any
process on the node could then attach to the kernel without a token.
ipykernel declares `debugpy` as a dependency but imports it only if it is
there, and any package that depends on ipykernel installs it again; so
`osp/finish-build.sh`, the last step of this image's build and of every image
built on it, removes it and checks that ipykernel finds no debugger.

**Servers a notebook starts: session hooks.** Some packages start servers when
a notebook calls them -- Dask's `Client()`, Ray's `ray.init()`. Under Apptainer
a session has no network of its own, so they listen on the node's network, and
without a login anyone who connects can run code in the session. Where a
package can require a login through its own settings alone, a **session hook**
does it: a small bash file the entrypoint sources at every session start,
which makes a secret in the session's private directory and points the
package's settings at it. The notebook does not change.

This image has neither Dask nor Ray, but images built on it may, so it ships
the hooks for both; each does nothing unless its package is installed:

- `osp/session.d/50-dask-tls.sh`: Dask requires mutual TLS, with a certificate
  made for the session.
- `osp/session.d/50-ray-token.sh`: Ray requires its token authentication, with
  a token made for the session; `finish-build.sh` refuses Ray older than 2.52,
  which has none.

They are also the examples to copy: `osp/session.d/README.md` explains why they
are there, the rules a hook follows, and how to write one for another package,
step by step on the Dask hook. Not covered: Dask's dashboard (`0.0.0.0:8787`,
no login; it shows tasks and logs and cannot run code;
`LocalCluster(dashboard_address=None)` turns it off), and servers that can only
be given a login where they are started (Bokeh or Panel servers, TensorBoard,
Streamlit, Gradio, PyTorch's distributed store).

**One loopback listener remains:** each kernel's pipe for output from
subprocesses it forks (a `127.0.0.1` port). It acts only on messages that carry
a random per-kernel key, so another session can neither read from it nor
inject into it.

**Scratch paths.** Bulk scratch goes under `$TMPDIR`, which the run profile
points at `<job directory>/tmp`; caches go in a per-session directory there
(`XDG_CACHE_HOME`, `MPLCONFIGDIR`). The entrypoint does not trust an inherited
`$TMPDIR`: a scheduler's `/scratch/$USER/job.N` is a host path Apptainer may
not bind, so it probes `$TMPDIR`, `/tmp`, `$HOME` in turn and reports on stderr
which it took. Do not bind a scratch parent (`--bind /scratch`) to make it
work: that shows the container every other job directory of the account.

## Notebook files

The notebook root is the caller's working directory — `-v "$PWD:/data"` under
Docker, and the job directory under Apptainer. Nothing is stored in the image,
and nothing a user saves outside the working directory survives the session.

## Build your own Jupyter image on this one

An image with your own Python packages is a repository with a few files and
this image as its base. You do not edit the `Dockerfile`; you list packages.

```
Dockerfile          (below, unchanged)
.dockerignore       (copy this repository's)
requirements.txt    Python packages, pip's format: one per line, e.g. pandas==2.3.3
apt.txt             optional: system packages (Debian names), only if a package needs one
session.d/          optional: your own session hooks (osp/session.d/README.md)
```

```dockerfile
# The base: JupyterLab behind the gate, hardened. Pin it by tag and the OCI
# image's digest (the image's, not the .sif's).
FROM ghcr.io/onescienceplace/app-jupyter:<version>@sha256:<digest>

COPY . /tmp/osp/
RUN /app/osp/install.sh /tmp/osp
RUN /app/osp/finish-build.sh
```

Copy `.github/workflows/build-and-push.yml` unchanged: it builds the image and
its `.sif`. Everything else -- the entrypoint, the gate, the session
directory, the run options -- comes from this image and works as described
above.

- **`install.sh`** installs `apt.txt`, then `requirements.txt` under
  `/app/osp/constraints.txt`: JupyterLab, Jupyter Server, ipykernel, pyzmq,
  tornado and their plumbing stay at the versions this image was built and
  validated with. A package that needs other versions of them fails the build
  with pip's explanation. Python packages go in `requirements.txt`, never in
  `apt.txt` (apt's would land in the OS's Python, which the kernels do not
  use). Then it adds the hooks in `session.d/`, refusing a name the image
  already has.
- **`finish-build.sh`** is always the last `RUN` line, as root (no `USER`
  line before it). It removes `debugpy` again, checks the Jupyter versions,
  the Unix socket, `pip check`, what the session files need and the session
  hooks (and that Ray, if installed, is 2.52 or later), and strips setuid and
  setgid bits (anything `apt.txt` installed included). It fails the
  build, naming the problem, rather than leaving it to a session.
- **Everything is installed at build time.** A `.sif` is read-only and
  compute nodes are often offline: `pip install` in a running session fails.
- **Your packages may start servers.** Dask and Ray are secured by the
  image's hooks. For anything else that starts a server from a notebook, see
  `osp/session.d/README.md`: write a hook if the package allows it, or say in
  your README how it is meant to be used. Keep a short script that starts them
  (`test/kernel-code-example.py` is one, for Dask and Ray): part B runs it with
  `validate.sh --kernel-code`, so the record lists every listener they open.
- **A new image is a new digest,** validated like any other (part B in
  `osp-ops`) before the portal offers it. A fix to this image reaches yours
  when you bump the `FROM` line.

## Build and test locally

Skip GitHub and the registry for the image itself (the build pulls the kit
image, `ghcr.io/onescienceplace/app-kit`, named in the `Dockerfile`):

```bash
docker build -t app-jupyter:dev .            # --platform linux/amd64 on Apple Silicon
export OSP_APP_TOKEN=$(openssl rand -hex 32)
docker run --rm --user "$(id -u):$(id -g)" \
  -p 127.0.0.1:8888:8888 -v "$PWD:/data" \
  -e OSP_APP_PORT=8888 -e OSP_APP_BIND=0.0.0.0 -e OSP_APP_TOKEN app-jupyter:dev

docker save app-jupyter:dev -o aj.tar
apptainer build aj.sif docker-archive://aj.tar
mkdir -p tmp
export APPTAINERENV_OSP_APP_TOKEN="$OSP_APP_TOKEN"
apptainer run \
  --contain --pid --ipc --cleanenv --no-mount bind-paths,cwd \
  --pwd "$PWD" --bind "$PWD:$PWD" \
  --env OSP_APP_PORT=8888 --env TMPDIR="$PWD/tmp" aj.sif
```

**Apple Silicon:** the image is linux/amd64 only. It builds under emulation
(`--platform linux/amd64`, slowly), but a session does not start there: the
session supervisor (`web/supervise.sh`, from the kit) checks each program it
starts by its name in `/proc/<pid>/comm`, and under emulation JupyterLab shows
as `python3.14`, not `jupyter-lab`, so the launch check ends the session. Run
sessions on an amd64 host.

JupyterLab refuses to start as uid 0, so the entrypoint sets
`--ServerApp.allow_root=True` for the Docker case; it is a no-op under
Apptainer, and a no-op with `--user` too.

Open `http://127.0.0.1:8888/?token=<the token>`. Locally there is no proxy in
front, so this is plain http and the URL keeps its token — through the
Satellite proxy the scheme is https and the entry path is otherwise identical.

### Why `--user`

Docker runs the container as root, so anything it writes into the bind-mounted
directory lands on your disk owned by `root` and needs `sudo` to delete.
`--user "$(id -u):$(id -g)"` makes the container write as you, and matches how
Apptainer runs it — Apptainer is always the invoking user, so it never has this
problem.

To reclaim files a previous root-owned run left behind:

```bash
sudo chown -R "$(id -u):$(id -g)" .
```

The one visible side effect: that uid has no `/etc/passwd` entry inside the
container, so `whoami` fails and `ls -l` shows bare numbers. Nothing actually
breaks — only code calling `getpwuid()` notices — and Apptainer generates the
entry itself, so this never shows up in production. If you want a name locally:

```bash
# 1. Let the entrypoint add one. /etc/passwd is group-writable in this image,
#    so running with group 0 is enough. You become `ospuser`.
docker run --rm --user "$(id -u):0" ...

# 2. Or show the container your real identity, keeping your own gid, so that
#    whoami returns your actual username.
docker run --rm --user "$(id -u):$(id -g)" \
  -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro ...
```

Set `OSP_APP_USER` to change the name option 1 uses.

`apptainer build` from a local archive needs no root and no fakeroot. Test the
`.sif` and not just the image, and test it under the run profile:
read-only-filesystem and small-`/tmp` bugs never show up under `docker run`.
