# app-jupyter

JupyterLab as an interactive `app-*` container — **branch A** of the
interactive contract: the app has native `?token=` auth, so it binds the single
exposed port directly and carries no nginx gate.

```
browser ──https──▶ Satellite ──http──▶ 0.0.0.0:OSP_APP_PORT   jupyter lab
```

## Run it

```bash
TOKEN=$(openssl rand -hex 32)

docker run --rm --user "$(id -u):$(id -g)" \
  -p 8888:8888 -v "$PWD:/data" \
  -e OSP_APP_PORT=8888 -e OSP_APP_TOKEN="$TOKEN" \
  ghcr.io/onescienceplace/app-jupyter:latest

apptainer pull oras://ghcr.io/onescienceplace/app-jupyter-sif:latest
apptainer run --env OSP_APP_PORT=8888 --env OSP_APP_TOKEN="$TOKEN" \
  app-jupyter-sif_latest.sif
```

Then open `https://<session>.<satellite-domain>/?token=$TOKEN`.

The container prints its port and entry path on startup, which is what the job
script needs to register the mapping with Satellite.

| Variable | Default | Meaning |
|---|---|---|
| `OSP_APP_PORT` | `8888` | the single port served |
| `OSP_APP_TOKEN` | generated | per-session secret; JupyterLab's own `?token=` |
| `OSP_APP_TOKEN_NAME` | `token` | fixed here — it is Jupyter's own parameter name |

## Why there is no gate

`OSP_APP_TOKEN_NAME` defaults to `token` precisely because that is what JupyterLab
uses. Setting `--ServerApp.token` satisfies the URL-token requirement with no
proxy in the middle, so `web/` here contains only `session-env.sh`.

`--ServerApp.trust_xheaders` is the one thing that matters for running behind
Satellite: TLS is terminated upstream, and without it Jupyter builds `ws://`
websocket URLs on an `https://` page and the browser refuses them.


## Kernels and scratch paths

The token is passed as `JUPYTER_TOKEN` in the environment, never as a command
line argument: `/proc/<pid>/cmdline` is world-readable, so `ps aux` on a shared
node would otherwise hand the session to anyone there. `/proc/<pid>/environ` is
`0400`.


Kernels run over **unix sockets, not TCP** (`--KernelManager.transport=ipc`).
Under Docker that would be cosmetic — loopback inside the container's own
network namespace — but Apptainer has no network namespace, so TCP kernel ports
would land on the compute node's real loopback, visible to every other user with
a shell there. The sockets come out `srwxr-xr-x`, and connecting to a unix
socket needs write permission, so nobody else can reach them.

`JUPYTER_CONFIG_DIR`, `JUPYTER_DATA_DIR`, `JUPYTER_RUNTIME_DIR` and
`IPYTHONDIR` are derived at startup from `$TMPDIR` and the runtime uid
(`$TMPDIR/jupyter-$(id -u)/…`). Jupyter creates these `0700`, so a fixed path
would leave the second user on a shared `/tmp` unable to write to a directory
the first one owns.

One consequence of keeping them under `/tmp`: the notebook-signing key is
regenerated every session, so notebook *trust* does not persist and saved
HTML/JS outputs need a re-run to render. Point `JUPYTER_DATA_DIR` at a path in
your home directory at run time if you want that to survive.

**Scratch paths.** The entrypoint does not trust `$TMPDIR`. A scheduler's
`/scratch/$USER/job.N` is a host path Apptainer does not bind by default, so it
probes `$TMPDIR`, `/tmp`, `$HOME` in turn and reports on stderr which it took.
Pass `--bind /scratch` if you want the real one used.

## Notebook files

The notebook root is the caller's working directory — `-v "$PWD:/data"` under
Docker, and whatever directory you ran from under Apptainer. Nothing is stored
in the image.

Everything Jupyter writes (`JUPYTER_RUNTIME_DIR`, config, data, IPython) is
redirected to `/tmp`, because the `.sif` filesystem is read-only.

## Build and test locally

Skip GitHub and the registry entirely:

```bash
docker build -t app-jupyter:dev .            # --platform linux/amd64 on Apple Silicon
docker run --rm --user "$(id -u):$(id -g)" \
  -p 8888:8888 -v "$PWD:/data" \
  -e OSP_APP_PORT=8888 -e OSP_APP_TOKEN=localdev app-jupyter:dev

docker save app-jupyter:dev -o aj.tar
apptainer build aj.sif docker-archive://aj.tar
apptainer run --env OSP_APP_PORT=8888 --env OSP_APP_TOKEN=localdev aj.sif
```

JupyterLab refuses to start as uid 0, so the entrypoint sets
`--ServerApp.allow_root=True` for the Docker case; it is a no-op under
Apptainer, and a no-op with `--user` too.

Open `http://localhost:8888/?token=localdev`. Locally there is no proxy in
front, so this is plain http and the URL keeps its token — under Satellite the
scheme is https and the entry path is otherwise identical.

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
`.sif` and not just the image: read-only-filesystem bugs never show up under
`docker run`.
