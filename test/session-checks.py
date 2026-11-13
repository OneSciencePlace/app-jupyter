#!/usr/bin/env python3
"""session-checks.py - run inside a test child's running session container by
test/run.sh (docker exec), as the session's user.

  inside <pid>   re-run with the environment of process <pid> (JupyterLab, whose
                 environment every kernel inherits) and check what a notebook
                 would see: the hooks' variables (paths only, files 0600 in the
                 session directory), no session token; then start a Dask
                 cluster and a Ray cluster the way a notebook does, run a task
                 on each, write their addresses to /tmp/osp-test/addr.json and
                 keep them up until /tmp/osp-test/done appears.
  outsider       with the plain environment of the container -- standing in
                 for another session on the node, which has none of this
                 session's secrets -- try to use those clusters: Dask without a
                 certificate and with one of its own, Ray's Jobs API and Ray's
                 control service without the token. Each must be refused.

Prints PASS / FAIL lines; exit 1 if anything failed. Prints no secret.
"""
import json
import os
import stat
import subprocess
import sys
import time

D = "/tmp/osp-test"
failed = 0


def report(ok, what, detail=""):
    global failed
    failed += 0 if ok else 1
    detail = " ".join(str(detail).split())
    detail = detail if len(detail) <= 100 else detail[:97] + "..."
    print(f"{'PASS' if ok else 'FAIL'}  {what:<52} {detail}".rstrip(), flush=True)


def private_file(path, sockdir):
    try:
        st = os.stat(path)
    except OSError:
        return False
    return path.startswith(sockdir + "/") and stat.S_IMODE(st.st_mode) & 0o077 == 0


def inside_run():
    env = os.environ
    sockdir = env.get("OSP_APP_SOCK_DIR", "")
    report(bool(sockdir), "session directory known", sockdir)
    report("OSP_APP_TOKEN" not in env, "no session token in the kernel environment")
    report(env.get("OSP_TEST_HOOK") == "ran", "the child's own hook ran (60-test-hook.sh)")

    # Dask: 50-dask-tls.sh
    report(env.get("DASK_DISTRIBUTED__COMM__REQUIRE_ENCRYPTION") == "True", "Dask: encryption required")
    for k in ("CA_FILE", "SCHEDULER__CERT", "WORKER__CERT", "CLIENT__CERT"):
        p = env.get(f"DASK_DISTRIBUTED__COMM__TLS__{k}", "")
        report(private_file(p, sockdir), f"Dask: {k} is a private file in the session dir")
    # Ray: 50-ray-token.sh
    report(env.get("RAY_AUTH_MODE") == "token", "Ray: RAY_AUTH_MODE=token")
    report("RAY_AUTH_TOKEN" not in env, "Ray: no token value in the environment")
    report(private_file(env.get("RAY_AUTH_TOKEN_PATH", ""), sockdir),
           "Ray: token is a private file in the session dir")

    from distributed import Client, LocalCluster
    cluster = LocalCluster(n_workers=1, threads_per_worker=1, dashboard_address=None)
    client = Client(cluster)
    report(cluster.scheduler_address.startswith("tls://"), "Dask: the session's cluster uses TLS",
           cluster.scheduler_address)
    report(client.submit(lambda: 6 * 7).result(timeout=60) == 42, "Dask: the session's client runs a task")

    import ray
    ctx = ray.init(include_dashboard=True, dashboard_host="127.0.0.1", log_to_driver=False)

    @ray.remote
    def f():
        return 42
    report(ray.get(f.remote(), timeout=120) == 42, "Ray: the session's cluster runs a task")

    os.makedirs(D, exist_ok=True)
    with open(f"{D}/addr.json", "w") as fh:
        json.dump({"dask": cluster.scheduler_address,
                   "ray_gcs": ctx.address_info["gcs_address"],
                   "ray_dashboard": ctx.dashboard_url}, fh)
    os.chmod(f"{D}/addr.json", 0o644)
    open(f"{D}/ready", "w").close()
    os.chmod(f"{D}/ready", 0o644)
    for _ in range(600):
        if os.path.exists(f"{D}/done"):
            break
        time.sleep(0.5)
    ray.shutdown()
    client.close()
    cluster.close()


def attempt(code, timeout):
    """Run code in a fresh interpreter with the outsider's environment; return
    (finished, printed). A connection that hangs counts as not connected."""
    try:
        r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=timeout)
        return True, (r.stdout + r.stderr)
    except subprocess.TimeoutExpired:
        return False, ""


def outsider():
    a = json.load(open(f"{D}/addr.json"))
    env_dask = [k for k in os.environ if k.startswith(("DASK_", "RAY_AUTH"))]
    report(not env_dask, "outsider has none of the session's settings")

    code = f"""
from distributed import Client
try:
    c = Client({a['dask']!r}, timeout=10)
    print("CONNECTED", c.submit(lambda: 1).result(timeout=10))
except Exception as e:
    print("refused:", type(e).__name__)
"""
    done, out = attempt(code, 60)
    report("CONNECTED" not in out, "Dask: a client without the certificate is refused",
           out.strip().splitlines()[-1] if out.strip() else "no connection within 60 s")

    # With a certificate of its own: what another session would have.
    own = f"{D}/outsider"
    os.makedirs(own, exist_ok=True)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                    "-nodes", "-days", "1", "-subj", "/CN=outsider", "-keyout", f"{own}/k.pem",
                    "-out", f"{own}/c.pem"], capture_output=True, check=True)
    with open(f"{own}/s.pem", "w") as fh:
        fh.write(open(f"{own}/k.pem").read() + open(f"{own}/c.pem").read())
    env = dict(os.environ,
               DASK_DISTRIBUTED__COMM__REQUIRE_ENCRYPTION="True",
               DASK_DISTRIBUTED__COMM__TLS__CA_FILE=f"{own}/c.pem",
               DASK_DISTRIBUTED__COMM__TLS__CLIENT__CERT=f"{own}/s.pem")
    try:
        r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=60, env=env)
        out = r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        out = ""
    report("CONNECTED" not in out, "Dask: a client with another certificate is refused",
           out.strip().splitlines()[-1] if out.strip() else "no connection within 60 s")

    import urllib.error
    import urllib.request
    try:
        r = urllib.request.urlopen(f"http://{a['ray_dashboard']}/api/jobs/", timeout=10)
        report(False, "Ray: Jobs API refuses a request without the token", f"HTTP {r.status}")
    except urllib.error.HTTPError as e:
        report(e.code in (401, 403), "Ray: Jobs API refuses a request without the token", f"HTTP {e.code}")
    except Exception as e:  # noqa: BLE001
        report(False, "Ray: Jobs API refuses a request without the token", type(e).__name__)

    code = f"""
import ray
try:
    ray.init(address={a['ray_gcs']!r}, log_to_driver=False)
    @ray.remote
    def g(): return 1
    print("CONNECTED", ray.get(g.remote(), timeout=20))
except Exception as e:
    print("refused:", type(e).__name__)
"""
    done, out = attempt(code, 90)
    report("CONNECTED" not in out, "Ray: a driver without the token is refused",
           out.strip().splitlines()[-1] if out.strip() else "no connection within 90 s")


if __name__ == "__main__":
    if sys.argv[1:2] == ["inside"]:
        pid = sys.argv[2]
        raw = open(f"/proc/{pid}/environ", "rb").read().split(b"\0")
        env = dict(kv.decode().split("=", 1) for kv in raw if b"=" in kv)
        os.execve(sys.executable, [sys.executable, __file__, "inside-run"], env)
    elif sys.argv[1:2] == ["inside-run"]:
        inside_run()
    elif sys.argv[1:2] == ["outsider"]:
        outsider()
    else:
        sys.exit(__doc__)
    sys.exit(1 if failed else 0)
