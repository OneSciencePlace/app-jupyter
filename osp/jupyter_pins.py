#!/usr/bin/env python3
"""jupyter_pins.py - hold the Jupyter software where app-jupyter put it.

  write <file>   at app-jupyter's own build, after its pip install: record the
                 installed versions of the packages below as pip constraints.
                 osp/install.sh installs every image's packages under them.
  check <file>   at the end of every build (osp/finish-build.sh): fail if any of
                 them now differs from <file>, if debugpy is installed, or if
                 ipykernel can find a debugger.

The packages are the server and the kernel and what carries their traffic:
what the gate, the Unix socket, the token setting (--IdentityProvider.token=)
and the kernels' ipc transport depend on. Other packages may move freely.
"""
import importlib.metadata as md
import sys

PINNED = [
    "jupyterlab",
    "jupyterlab-server",
    "jupyter-server",
    "jupyter-server-terminals",
    "terminado",
    "jupyter-client",
    "jupyter-core",
    "ipykernel",
    "pyzmq",
    "tornado",
]

HEADER = """\
# Written by osp/jupyter_pins.py at app-jupyter's build: the Jupyter server,
# kernel and their transport, at the versions this image was built and
# validated with. osp/install.sh installs every image's packages under these;
# osp/finish-build.sh checks they still hold. Do not edit.
"""


def version(name):
    try:
        return md.version(name)
    except md.PackageNotFoundError:
        return None


def write(path):
    lines = []
    for name in PINNED:
        v = version(name)
        if v is None:
            sys.exit(f"jupyter_pins: {name} is not installed")
        lines.append(f"{name}=={v}")
    with open(path, "w") as f:
        f.write(HEADER + "\n".join(lines) + "\n")
    print("\n".join(f"[pins] {line}" for line in lines))


def check(path):
    problems = []
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            name, want = line.split("==", 1)
            have = version(name)
            if have != want:
                problems.append(f"{name} is {have or 'not installed'}, this image needs {want}")
    if version("debugpy") is not None:
        problems.append("debugpy is installed (finish-build.sh removes it; was it reinstalled later?)")
    import ipykernel.debugger  # noqa: E402  after the debugpy check on purpose
    if ipykernel.debugger._is_debugpy_available:
        problems.append("ipykernel finds a debugger: JupyterLab would offer it, and it listens on TCP")
    if problems:
        for p in problems:
            print(f"jupyter_pins: {p}", file=sys.stderr)
        sys.exit(1)
    print("[pins] Jupyter versions as built; no debugger")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("write", "check"):
        sys.exit("usage: jupyter_pins.py write|check <constraints file>")
    {"write": write, "check": check}[sys.argv[1]](sys.argv[2])
