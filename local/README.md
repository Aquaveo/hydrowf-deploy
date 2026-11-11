# Local cluster

kind + Argo Workflows v4.1.6 + [RustFS](https://github.com/rustfs/rustfs) as the S3 artifact store,
for running hydrowf pipelines on one machine. Local development only: fixed credentials, no auth.

```sh
./up.sh      # create the cluster (or update it) and wait until it's ready
./down.sh    # delete it, with everything in it
```

| What | Where |
|---|---|
| Argo UI | https://localhost:2746 (self-signed certificate, no login) |
| S3 API | http://localhost:9000, bucket `my-bucket`, `admin` / `password` |
| RustFS console | http://localhost:9001 |
| kubectl / argo context | `kind-hydrowf`, namespace `argo` |

Needs Docker, [kind](https://kind.sigs.k8s.io/), kubectl, curl, and the
[argo CLI](https://github.com/argoproj/argo-workflows/releases/tag/v4.1.6) to submit workflows.

## What's in it

- `kind-config.yaml`: one node (Kubernetes 1.37), with the UI and S3 ports mapped to localhost.
- `kustomization.yaml`: the Argo v4.1.6 quick-start (release asset, by URL; `up.sh` checks its
  sha256) with three changes: its S3 server is removed, and the `argo-server` and `minio`
  Services become NodePorts.
- `rustfs.yaml`: RustFS on a 50 Gi volume, behind the quick-start's `minio` Service and with its
  credentials, so Argo's artifact repository works unchanged. An init container creates
  `my-bucket` (a folder in the data dir is a bucket). RustFS replaces the quick-start's MinIO
  fork: the MinIO community edition is archived, and RustFS is Apache-2.0.

The bucket is on a volume, so it survives a RustFS pod restart; `down.sh` deletes it.

## Running hydrowf pipelines

Images that are only local have to be loaded into the node, and pipeline inputs go in the bucket:

```sh
kind load docker-image --name hydrowf hydrowf/ngiab-preprocess:4.9.5.dev2-02c4145 \
  hydrowf/ngiab-calibrate:0.2.0 hydrowf/ngiab-to-cng:0.1.0
export AWS_ACCESS_KEY_ID=admin AWS_SECRET_ACCESS_KEY=password AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url http://localhost:9000 s3 cp conus_nextgen.gpkg s3://my-bucket/hydrofabric/v2.2/
aws --endpoint-url http://localhost:9000 s3 cp conus_igraph_network.gpickle s3://my-bucket/hydrofabric/v2.2/
```

Then translate and submit with hydrowf-platform (`hydrowf-cwl2argo`, see its README).

## Smoke test

```sh
argo submit -n argo --watch https://raw.githubusercontent.com/argoproj/argo-workflows/v4.1.6/examples/artifact-passing.yaml
```
