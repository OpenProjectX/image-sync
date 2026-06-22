# image-sync

Mirror container images from public registries (Docker Hub, quay.io,
registry.k8s.io, …) into [GHCR](https://ghcr.io) under
**`ghcr.io/openprojectx`** using [skopeo](https://github.com/containers/skopeo).

Useful when you want a stable, rate-limit-free, geographically closer copy of
upstream images that your clusters and CI can pull from a single namespace.

## How it works

1. [`images.yaml`](images.yaml) declares the images to mirror.
2. [`scripts/sync.sh`](scripts/sync.sh) reads that file and runs
   `skopeo copy` for each entry into `ghcr.io/openprojectx`.
3. The [`Sync images to GHCR`](.github/workflows/sync.yml) workflow runs the
   script on a daily schedule, on every change to the image list, and on
   manual dispatch. It authenticates to GHCR with the built-in `GITHUB_TOKEN`.

The destination encodes the **source registry** as a leading namespace, so
images with the same name from different registries never collide:

```
docker.io/library/nginx:1.27  ->  ghcr.io/openprojectx/dockerhub/library/nginx:1.27
registry.k8s.io/pause:3.10    ->  ghcr.io/openprojectx/k8s/pause:3.10
quay.io/skopeo/stable:latest  ->  ghcr.io/openprojectx/quay/skopeo/stable:latest
```

Registry aliases: `docker.io` → `dockerhub`, `registry.k8s.io` → `k8s`,
`quay.io` → `quay`, `gcr.io` → `gcr`, `ghcr.io` → `ghcr`,
`mcr.microsoft.com` → `mcr`, `public.ecr.aws` → `ecr`. Unknown hosts use the
host name verbatim.

## Adding an image

Edit [`images.yaml`](images.yaml):

```yaml
images:
  - source: docker.io/library/redis:7.4      # -> ghcr.io/openprojectx/dockerhub/library/redis:7.4
  - source: registry.k8s.io/coredns/coredns:v1.11.1
                                              # -> ghcr.io/openprojectx/k8s/coredns/coredns:v1.11.1
  - source: quay.io/prometheus/prometheus:v2.53.0
    target: monitoring/prometheus:v2.53.0     # explicit destination overrides the default
  - source: docker.io/library/nginx:1.27
    all: false                                # copy only the runner's arch
```

- `source` — full upstream reference (`registry/repo:tag` or `…@sha256:…`).
- `target` *(optional)* — explicit destination `repo[:tag]` under
  `ghcr.io/openprojectx`. **Omit it** to use the default convention
  (`<registry-alias>/<upstream/repo/path>:<tag>`); supply it only when you
  want a custom path.
- `all` *(optional, default `true`)* — mirror every architecture in the
  manifest list (`skopeo copy --all`).

Commit to `main` and the workflow re-syncs automatically.

## Caching across runs

Before copying, the script compares the raw manifest of the source against the
one already in GHCR. If they're identical the image is **skipped** — so a
scheduled run only transfers tags that actually changed upstream, and unchanged
tags cost a single cheap manifest lookup. (skopeo also never re-uploads layers
that already exist at the destination, so even changed images reuse shared
layers.)

Set `FORCE=true` (or tick **force** on the manual run) to re-copy everything
regardless.

## Running locally

Requires `skopeo` and `yq` (v4, mikefarah).

```bash
# Preview without pushing
DRY_RUN=true bash scripts/sync.sh

# Real sync (must be logged in to ghcr.io with packages:write)
echo "$GITHUB_TOKEN" | skopeo login ghcr.io -u <your-username> --password-stdin
bash scripts/sync.sh
```

Environment variables: `GHCR_NAMESPACE` (default `ghcr.io/openprojectx`),
`IMAGES_FILE` (default `images.yaml`), `DRY_RUN`, and `GHCR_USERNAME` /
`GHCR_TOKEN` for in-script login.

## Notes

- New packages are private by default. To make a mirror public, open the
  package in the org's **Packages** settings and change its visibility (or set
  it once via the API).
- The `GITHUB_TOKEN` only has `packages: write` for the `OpenProjectX` org, so
  the workflow can push to `ghcr.io/openprojectx/*` out of the box.
