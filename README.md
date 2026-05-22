# CyberPulse Installer

This repository contains the public production installer and Helm chart for CyberPulse.

CyberPulse application images are prebuilt and hosted as private GitHub Container Registry packages under `ghcr.io/solutionscst`. The installer is public, but a customer-specific GHCR username and read-only package access token are required to pull the images.

## Prerequisites

```bash
# Install k3s
curl -sfL https://get.k3s.io | sh -

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install Python cryptography for first-run key generation
pip3 install cryptography
```

## Install

```bash
./install.sh
```

The installer prompts for:

- CyberPulse image tag, such as `v1.2.0`
- GitHub/GHCR username
- GitHub/GHCR access token

For a specific release:

```bash
CYBERPULSE_IMAGE_TAG=v1.2.0 ./install.sh
```

With customer-specific values:

```bash
CYBERPULSE_IMAGE_TAG=v1.2.0 \
CYBERPULSE_VALUES_FILE=examples/values.example.yaml \
./install.sh
```

## What It Does

The installer:

1. Creates `data`, `dmz`, and `internal` namespaces.
2. Installs or updates PostgreSQL with Helm.
3. Creates GHCR image pull secrets in the app namespaces.
4. Generates application secrets on first install.
5. Runs `helm upgrade --install` for the CyberPulse chart.
6. Waits for the webapp, FastAPI, and worker rollouts.

Generated application secrets are backed up to `secrets/prod-secrets.yaml`. GHCR credentials are stored only as Kubernetes image pull secrets.

## Network Access

The chart creates an HTTP-only Traefik Ingress for the webapp. With the default hostless setting, CyberPulse is exposed through the k3s/Traefik server address:

```text
http://<server-ip>/
```

Only the webapp is exposed. FastAPI remains internal and is reached through the webapp container's `/api/` nginx proxy. PostgreSQL and Redis remain internal-only.

## Updates

Run the installer again with the new image tag:

```bash
CYBERPULSE_IMAGE_TAG=v1.2.1 ./install.sh
```

FastAPI applies database migrations during startup.

## Uninstall

To remove the production/installer deployment from a local test cluster:

```bash
./uninstall.sh
```

This removes the CyberPulse Helm release, PostgreSQL Helm release, `dmz`, `internal`, and `data` namespaces, Kubernetes secrets, PVC-backed data, and local CyberPulse images where possible.

For non-interactive local cleanup:

```bash
CYBERPULSE_ASSUME_YES=true ./uninstall.sh
```