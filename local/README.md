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
  sha256) with these changes: its S3 server is removed, the `argo-server` and `minio` Services
  become NodePorts, and workflow pods (service account `default`) may no longer create pods or
  workflows (see [Steps that read in place](#steps-that-read-in-place)), and the controller runs without a
  parallelism limit or retention policy (see [Argo's controller limits](#argos-controller-limits)).
- `hydrowf-ogc.yaml`: hydrowf-ogc's service account for its step-key vendor: create TokenReviews, get
  pods in `argo`, nothing else.
- `rustfs.yaml`: RustFS on a 50 Gi volume, behind the quick-start's `minio` Service and with its
  credentials, so Argo's artifact repository works unchanged. An init container creates
  `my-bucket` (a folder in the data dir is a bucket). RustFS replaces the quick-start's MinIO
  fork: the MinIO community edition is archived, and RustFS is Apache-2.0.

The bucket is on a volume, so it survives a RustFS pod restart; `down.sh` deletes it.

`up.sh` applies these files over whatever the cluster has. On a cluster it didn't make (or made from older
files), run `kubectl --context kind-hydrowf diff -k .` first: an apply that changes RustFS's volume starts it
on an empty one.

## Argo's controller limits

The quick-start's controller config limits a namespace to 10 running workflows and keeps only the newest 10
completed (3 failed) workflows. Both are wrong for hydrowf, so `kustomization.yaml` sets
`namespaceParallelism: "0"` (no limit) and removes `retentionPolicy`:

- **Kept jobs count as running.** render gives every job `artifactGC: OnWorkflowDeletion`, so a finished job
  keeps Argo's `workflows.argoproj.io/artifact-gc` finalizer until it is deleted. Argo v4.1.6 keeps any
  workflow with that finalizer in its parallelism count (`reconciliationNeeded` in
  workflow/controller/controller.go; the throttler only frees a slot when that is false, or on deletion).
  With a limit of 10, new jobs stay `Pending` ("too many workflows are already running") once 10 finished
  jobs are kept. The global `parallelism` counts the same way.
- **Retention deletes outputs.** Argo deletes workflows past `retentionPolicy`'s counts, and deleting a job
  deletes its outputs (artifact GC). Jobs are kept for render's per-job `ttlStrategy` instead (hydrowf-ogc:
  30 days, `retention`).

On EKS the same holds: leave both unset in the controller config, and limit how much runs at once with the
cluster's capacity (requests, the autoscaler's maximum), not Argo's parallelism. hydrowf-ogc has no per-user
limit on running jobs yet (its docs/ogc.md plans only a storage quota): until it has one, a single caller can
fill the cluster.

A cluster changed with `kubectl patch` before this needs `kubectl apply --server-side --force-conflicts` on the
config map once (the patch owns the field), or `up.sh` stops on a conflict.

## Running hydrowf pipelines

Images that are only local have to be loaded into the node, and pipeline inputs go in the bucket:

```sh
kind load docker-image --name hydrowf hydrowf/ngiab-preprocess:4.9.5.dev2-02c4145 \
  hydrowf/ngiab-calibrate:0.2.0 hydrowf/ngiab-to-cng:0.1.0
export AWS_ACCESS_KEY_ID=admin AWS_SECRET_ACCESS_KEY=password AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url http://localhost:9000 s3 cp conus_nextgen.gpkg s3://my-bucket/hydrofabric/v2.2/
aws --endpoint-url http://localhost:9000 s3 cp conus_igraph_network.gpickle s3://my-bucket/hydrofabric/v2.2/
```

Then render and submit a pipeline lego with hydrowf-core (`hydrowf_core.adapters.argo.render`,
`ArgoRuntime`, see its README).

## Smoke test

```sh
argo submit -n argo --watch https://raw.githubusercontent.com/argoproj/argo-workflows/v4.1.6/examples/artifact-passing.yaml
```

## Read keys for job outputs (hydrowf-ogc `GET /ogc/jobs/{id}/credentials`)

hydrowf-ogc hands a job's owner short-lived keys that may only read that job's outputs (S3 STS
`AssumeRole` with a session policy). Their parent must be a read-only identity, never the admin key:

```bash
kubectl --context kind-hydrowf -n argo port-forward svc/minio 9000:9000 &
./s3-reader.sh        # user hydrowf-reader, policy hydrowf-read (s3-reader-policy.json), Secret hydrowf-s3-reader
```

Then run hydrowf-ogc with `HYDROWF_S3_READER_ACCESS_KEY` / `HYDROWF_S3_READER_SECRET_KEY` from the Secret
`hydrowf-s3-reader`, `HYDROWF_STS_ENDPOINT=http://localhost:9000`, and a `credentials: {role_arn:
arn:aws:iam::0:role/hydrowf-reader}` section in its manager config (RustFS takes any ARN). The script is
safe to run again and prints no keys.

**On EKS** there is no reader user: hydrowf-ogc's pod has an IAM role (EKS Pod Identity or IRSA) allowed to
`sts:AssumeRole` a role `hydrowf-reader`, and `credentials.role_arn` names that role.
- `hydrowf-reader`'s permissions: `s3:GetObject` on `arn:aws:s3:::<bucket>/*` and `s3:ListBucket` on the
  bucket, nothing else (as `s3-reader-policy.json`). The session policy hydrowf-ogc adds narrows it to one
  job's outputs.
- Its trust policy names only hydrowf-ogc's role. With EKS Pod Identity the pod's session carries tags;
  check whether chaining into `hydrowf-reader` needs `sts:TagSession` in that trust policy too.
- Role chaining caps a session at 1 hour, so `credentials.duration` is 900 to 3600 (default 900).
- Sessions can't call GetBucketLocation: set `credentials.region` to the bucket's region (readers pass it).
- Not verified on AWS yet: a read of a missing key may answer 403 rather than 404 (hydrowf-ogc docs/ogc.md,
  Known gaps). Test a sparse Zarr before relying on it.

## Steps that read in place (hydrowf-ogc's step-key vendor)

A step whose dataset port reads the bucket in place (a job output or managed data) gets one-hour read keys for
exactly what it reads: its init container sends the pod's projected token (audience `hydrowf-vendor`) to
hydrowf-ogc's internal port 8001, which checks it with a TokenReview and reads the pod (hydrowf-ogc docs/ogc.md,
"Steps that read in place"). `hydrowf-ogc.yaml` gives hydrowf-ogc those two rights. hydrowf-ogc runs in Docker
beside kind, so it takes that account's token from a file:

```bash
./vendor-access.sh    # writes the token and the cluster CA to ~/.config/hydrowf/kind-hydrowf (mode 600), prints no token
```

It prints the rest: run hydrowf-ogc with `--network host --user "$(id -u)"`, that folder mounted, and the
`HYDROWF_K8S_API` / `HYDROWF_K8S_TOKEN_FILE` / `HYDROWF_K8S_CA_FILE` settings; and add `credentials.steps` to
its manager config. Step pods reach it at the kind network's gateway (`http://172.18.0.1:8001/step-keys` on a
default Docker setup); the tools reach RustFS at `http://minio.argo.svc.cluster.local:9000`. The vendor
listens on every interface of this machine, but answers only tokens the cluster signed for a running step.

**What it relies on.** The vendor trusts the workflow's record of what each step reads, and that the pod asking
is the one Argo made for the step. So only hydrowf-ogc may create workflows (through Argo), and nothing in the
workflows' namespace but Argo's controller may create pods, `pods/exec` or service-account tokens. Workflow pods
run as `default`, which the quick-start lets create pods and workflows; `kustomization.yaml` removes those
bindings, and agent's (`up.sh` also deletes them from older clusters). What `default` may still do:

```bash
kubectl --context kind-hydrowf auth can-i --list -n argo --as system:serviceaccount:argo:default
# workflowtaskresults create/patch (executor), workflowartifactgctasks (artifactgc)
```

Executor's task results let a tool write another step's output parameters and artifact keys (Argo's own
limit); that doesn't reach the vendor, whose keys come only from what render recorded at submission.

**On kind the boundary doesn't hold, by design of a development cluster:** argo-server runs in `server` auth
mode, so any pod can submit workflows through `https://argo-server.argo:2746` with no token, and RustFS's admin
key is the published `admin` / `password`. Use it to test the mechanism, not the isolation.

**On EKS** hydrowf-ogc runs in a pod with its own service account and uses its mounted token (no
`HYDROWF_K8S_*`, no token Secret):
- Bind that account the same two rights as `hydrowf-ogc.yaml` (create TokenReviews cluster-wide, get pods in
  the workflows' namespace); it creates nothing else through the Kubernetes API. Workflows are submitted through
  argo-server with `HYDROWF_ARGO_TOKEN`: the identity behind it is the one that may create workflows, and only
  hydrowf-ogc holds it.
- argo-server runs in `client` or `sso` auth mode (never `server`), and a NetworkPolicy lets only hydrowf-ogc
  reach its port 2746.
- The workflows' service account gets the executor and artifactgc rights only. Check it with
  `kubectl auth can-i --list` as above.
- The artifact repository's S3 credentials are not readable by tools (no `get secrets` in that namespace for
  the workflows' account), and the workflows' service account has no IAM role (IRSA or Pod Identity) that
  reaches the bucket: every container in a pod shares that role, the tool's included. Give Argo's artifact
  repository a key in a Secret instead, which Argo hands only to its own containers.
- `vendor_url` is `http://<hydrowf-ogc Service>.<namespace>.svc:8001/step-keys`. The ingress routes port 8000
  only, and a NetworkPolicy keeps 8001 for the workflows' namespace. With the Amazon VPC CNI, policies are
  enforced only once its network policy support is turned on.
- The port-8000 rule below assumes an in-cluster ingress controller. With the AWS Load Balancer Controller in IP
  target mode, traffic comes from the load balancer's addresses, not from a namespace: allow its subnets with
  an `ipBlock` instead.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: hydrowf-ogc, namespace: <hydrowf-ogc's namespace>}
spec:
  podSelector: {matchLabels: {app: hydrowf-ogc}}
  policyTypes: [Ingress]
  ingress:
    - ports: [{port: 8000}]                      # the public API, through the ingress
      from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: <ingress namespace>}}}]
    - ports: [{port: 8001}]                      # the step-key vendor: step pods only
      from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: argo}}}]
```
