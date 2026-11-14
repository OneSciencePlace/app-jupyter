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

# Ray (secured by 50-ray-token.sh: token authentication).
import ray
ray.init(include_dashboard=True, log_to_driver=False)
print("ray", ray.get(ray.remote(lambda: 42).remote()))
