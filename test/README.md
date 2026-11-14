# Tests for app-jupyter as a base image

`bash test/run.sh <image> [--negative]` builds `test/child/` on the given
app-jupyter image, exactly as the README's "Build your own Jupyter image on
this one" describes, and checks what app-jupyter promises to images built on
it:

- `osp/install.sh`: packages installed, the child's own hook added;
- `osp/finish-build.sh`: debugpy removed again (the child's `jupyter-console`
  brings it back), the hooks checked, Ray's version accepted, setuid bits
  stripped (the child's `sudo`);
- the session hooks, in a running session: as a notebook, Dask and Ray
  clusters work with the settings the hooks made (paths only, private files in
  the session directory); as another session, without those secrets, both are
  refused (Dask with no certificate and with one of its own; Ray's Jobs API and
  its control service without the token);
- with `--negative`, five builds that must fail, each for its stated reason.

Run it on the branch image before a release
(`ghcr.io/onescienceplace/app-jupyter:sha-<short>`), and whenever
`osp/` changes. It needs Docker, nothing else; on Apple Silicon it runs under
emulation and takes a while.

This is not part B. An image's part B is `tools/validate.sh` in `osp-ops`,
under the run profile; this tests the build tools and hooks that every image
built on app-jupyter inherits.

`kernel-code-example.py` is for that part B: `validate.sh app --kind web
--kernel-code <file>` runs it in a session's kernel before the host check, so
the servers it starts (here Dask's and Ray's) are among the listeners the
record lists. Images built on app-jupyter copy it and keep what they ship.
