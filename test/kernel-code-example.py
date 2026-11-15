# kernel-code-example.py - for osp-ops tools/validate.sh app --kind web
# --kernel-code <this file>: start the servers an image's packages provide, the
# way a notebook would, so that part B's host check lists their listeners and
# the record says how each is secured. Copy it into an image built on
# app-jupyter and keep the parts for what that image ships.
#
# Dask (secured by 50-dask-tls.sh: the scheduler's address should be tls://).
from distributed import Client, LocalCluster
cluster = LocalCluster(n_workers=1, threads_per_worker=1)
client = Client(cluster)
print("dask", cluster.scheduler_address, client.submit(lambda: 6 * 7).result())
# What each Dask port is ("listener <host:port> <role>", for osp-ops'
# listener-check.py, which validate.sh runs on every listener besides the gate).
from urllib.parse import urlparse
def hostport(addr):
    u = urlparse(addr)
    return f"{u.hostname}:{u.port}"
print("listener", hostport(cluster.scheduler_address), "dask-scheduler")
dash = cluster.scheduler_info.get("services", {}).get("dashboard")
if dash:
    print("listener", f"0.0.0.0:{dash}", "dask-dashboard (NEW-19: no login; shows tasks and logs)")
for waddr, w in client.scheduler_info()["workers"].items():
    print("listener", hostport(waddr), "dask-worker")
    if w.get("nanny"):
        print("listener", hostport(w["nanny"]), "dask-nanny")
    for name, port in (w.get("services") or {}).items():
        print("listener", f"127.0.0.1:{port}", f"dask-worker-{name} (NEW-19: /health, /metrics; no login)")
pipe = getattr(getattr(get_ipython().kernel, "iopub_thread", None), "_pipe_port", None)
print("listener", f"127.0.0.1:{pipe}" if pipe else "?:0", "kernel-subprocess-pipe (signed with the kernel's key)")

# Ray (secured by 50-ray-token.sh: token authentication). Its many ports
# (control service, raylet, object manager, dashboard, agents, one per worker)
# get no role lines yet: listener-check.py marks them "no role given".
import ray
ray.init(include_dashboard=True, log_to_driver=False)
print("ray", ray.get(ray.remote(lambda: 42).remote()))
