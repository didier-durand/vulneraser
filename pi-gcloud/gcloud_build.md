# gcloud_build.sh — Build & Push Container Images to Google Cloud

Build container images locally and push them to Google Cloud Artifact Registry.

The script builds both images defined in this repo — `pi-rpc` (Pi agent in RPC mode) and `open-code-review` (Open Code Review CLI) — tags them with `latest` and the current git SHA, and pushes them to Artifact Registry.

---

## Prerequisites

| Requirement | Details |
|---|---|
| Google Cloud CLI | Installed and authenticated (`gcloud auth login`) |
| Docker | Running locally |
| GCP project | Set via `gcloud config set project <ID>` or `-p` flag |
| Artifact Registry repo | Created once (see below) |
| Cloud APIs enabled | `artifactregistry.googleapis.com` |

### Create the Artifact Registry repository (one-time)

```bash
gcloud artifacts repositories create vulneraser \
    --repository-format=docker \
    --location=us-central1
```

### Configure Docker for Artifact Registry (one-time)

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev
```

The script runs this automatically when pushing, but running it once beforehand avoids repeated prompts.

### Enable the Artifact Registry API (one-time)

```bash
gcloud services enable artifactregistry.googleapis.com
```

---

## Usage

```bash
./gcloud_build.sh [options]
```

### Options

| Flag | Default | Purpose |
|---|---|---|
| `-r, --region <region>` | `us-central1` | Artifact Registry region |
| `-R, --repository <name>` | `vulneraser` | Artifact Registry repository name |
| `-p, --project <id>` | `gcloud config` value | GCP project ID |
| `-t, --tag <tag>` | — | Extra tag in addition to `latest` and git SHA (e.g. `v1.0`) |
| `-i, --image <name>` | `both` | Build only one image: `pi-rpc`, `ocr`, or `both` |
| `--no-push` | (off) | Build locally but don't push to Artifact Registry |
| `-h, --help` | — | Show help and exit |

---

## Examples

### Build and push both images

```bash
./gcloud_build.sh
```

### Build and push only the pi-rpc image

```bash
./gcloud_build.sh -i pi-rpc
```

### Build and push only the open-code-review image

```bash
./gcloud_build.sh -i ocr
```

### Use a custom region and repository

```bash
./gcloud_build.sh -r europe-west1 -R vulneraser
```

### Specify the GCP project explicitly

```bash
./gcloud_build.sh -p my-gcp-project-123
```

### Add a semantic version tag

```bash
./gcloud_build.sh -t v1.0
```

This produces three tags per image: `latest`, `<git-sha>`, and `v1.0`.

### Build locally without pushing (dry run)

```bash
./gcloud_build.sh --no-push
```

Useful for verifying the Dockerfiles build cleanly before pushing to GCP.

### Combine options

```bash
./gcloud_build.sh -r europe-west1 -R vulneraser -p my-project -t v1.0 -i pi-rpc
```

---

## What the script does

1. Resolves the GCP project ID from `gcloud config` or the `-p` flag.
2. Determines the current git short SHA (falls back to `local` if not in a git repo).
3. Configures Docker for Artifact Registry authentication (`gcloud auth configure-docker`).
4. Builds each requested image with `docker build`, tagging it as:
   - `<region>-docker.pkg.dev/<project>/<repo>/<image>:latest`
   - `<region>-docker.pkg.dev/<project>/<repo>/<image>:<git-sha>`
   - `<region>-docker.pkg.dev/<project>/<repo>/<image>:<extra-tag>` (if `-t` is set)
5. Pushes each tag to Artifact Registry with `docker push` (unless `--no-push`).
6. Prints the final image locations.

---

## Image names and tags

The script builds and tags these images:

| Image | Dockerfile | Tags |
|---|---|---|
| `pi-rpc` | `Dockerfile_pi_rpc` | `latest`, `<git-sha>`, `<extra-tag>` |
| `open-code-review` | `Dockerfile_ocr` | `latest`, `<git-sha>`, `<extra-tag>` |

Full image path format:

```
<region>-docker.pkg.dev/<project-id>/<repository>/<image>:<tag>
```

Example with defaults:

```
us-central1-docker.pkg.dev/my-project/vulneraser/pi-rpc:latest
us-central1-docker.pkg.dev/my-project/vulneraser/pi-rpc:f77e97a
us-central1-docker.pkg.dev/my-project/vulneraser/open-code-review:latest
us-central1-docker.pkg.dev/my-project/vulneraser/open-code-review:f77e97a
```

---

## Pulling the images

After pushing, pull the image on any machine with access to the registry:

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev
docker pull us-central1-docker.pkg.dev/my-project/vulneraser/pi-rpc:latest
docker pull us-central1-docker.pkg.dev/my-project/vulneraser/open-code-review:latest
```

### Run pi-rpc from Artifact Registry

```bash
docker run --rm -p 9471:9471 -e OPENAI_API_KEY=sk-... \
    us-central1-docker.pkg.dev/my-project/vulneraser/pi-rpc:latest
```

### Run open-code-review from Artifact Registry

```bash
docker run --rm -v "$PWD:/workspace" \
    us-central1-docker.pkg.dev/my-project/vulneraser/open-code-review:latest review
```

---

## Using Cloud Build instead

For fully serverless builds on Google Cloud, use `cloudbuild.yaml`:

```bash
gcloud builds submit --config cloudbuild.yaml \
    --substitutions=_REGION=us-central1,_REPOSITORY=vulneraser \
    .
```

See the [cloudbuild.yaml](cloudbuild.yaml) file for details.

---

## Troubleshooting

### `no GCP project ID set`

Run one of:

```bash
gcloud config set project my-project-id
# or
./gcloud_build.sh -p my-project-id
```

### `denied: permission denied` on push

Ensure you're authenticated and the repository exists:

```bash
gcloud auth login
gcloud auth configure-docker us-central1-docker.pkg.dev
gcloud artifacts repositories describe vulneraser --location us-central1
```

### `repository not found`

Create it:

```bash
gcloud artifacts repositories create vulneraser \
    --repository-format=docker --location us-central1
```

### Build fails with `docker build` error

Ensure Docker is running and the Dockerfiles exist in the repo root:

```bash
ls -l Dockerfile_pi_rpc Dockerfile_ocr
```

Test a build in isolation first:

```bash
./gcloud_build.sh --no-push -i pi-rpc
```

### Wrong region

Use the same region for build, push, and pull. Override with `-r`:

```bash
./gcloud_build.sh -r europe-west1
```

---

## Reference

- [Artifact Registry documentation](https://cloud.google.com/artifact-registry/docs)
- [Docker formatting for Artifact Registry](https://cloud.google.com/artifact-registry/docs/docker-authenticate)
- [Cloud Build documentation](https://cloud.google.com/build/docs)
- [gcloud CLI reference](https://cloud.google.com/sdk/gcloud/reference)
