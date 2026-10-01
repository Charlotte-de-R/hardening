# Container Hardening Repository 🛡️

Automated build pipeline and hardening configuration for container images published to `ghcr.io`.

## 📌 Architecture & Features

This repository automates the process of fetching upstream application releases, injecting security hardening steps into Dockerfiles, building hardened container images, signing them with Cosign, scanning for vulnerabilities with Trivy, and publishing them to GitHub Container Registry (`ghcr.io`).

### 🔑 Key Features
* **Universal Security Hardening (`templates/universal_hardening.txt`)**:
  - Automatically updates Alpine (`apk`) / Debian (`apt-get`) OS packages and security libraries (e.g., `libssl3`, `libcrypto3`, `zlib`, `sqlite`).
  - Purges insecure tools (`vim`, `nano`, `git`, `telnet`, `ftp`) and cleans package caches.
  - Upgrades vulnerable runtime dependencies (Node.js npm / Python pip packages).
  - Cleanups temporary files and optimizes layers for Trivy scanning.
* **Automated Update Detection (`check_update.sh`)**:
  - Monitors upstream GitHub releases / tags (e.g., Tailscale, CrowdSec, Vaultwarden, Immich, Tetragon, Portainer, CryptPad, Nextcloud).
  - Checks if OS-level package updates are pending inside existing container images.
* **GitHub Actions CI/CD Pipeline (`scheduled-harden.yml`)**:
  - Runs daily scheduled builds using Docker Buildx matrix strategy.
  - Accelerates build speeds with GitHub Actions cache (`type=gha`).
  - Signs images with **Cosign** Keyless OIDC signatures.
  - Scans images for `CRITICAL` vulnerabilities with **Trivy** and uploads SARIF reports to GitHub Security Code Scanning tab.

---

## 📁 Repository Structure

```text
.
├── .github/workflows/
│   └── scheduled-harden.yml    # GitHub Actions workflow for automated build, scan, sign & publish
├── templates/
│   └── universal_hardening.txt # Universal hardening snippet injected into Dockerfiles
├── dockerfiles/
│   ├── crowdsec/
│   ├── cryptpad/
│   ├── immich-machine-learning/
│   ├── immich-postgres/
│   ├── immich-redis/
│   ├── immich-server/
│   ├── mariadb/
│   ├── nextcloud/
│   ├── portainer/
│   ├── promtail/
│   ├── socket-proxy/
│   ├── tailscale/
│   ├── tetragon/
│   └── vaultwarden/
├── check_update.sh             # Upstream release & OS update check script
├── update_dockerfiles.sh       # Script to inject universal_hardening.txt into Dockerfiles
└── README.md
```

---

## 🛠️ Usage & Operations

### 1. Updating Hardening Templates Across All Dockerfiles
When modifications are made to `templates/universal_hardening.txt`, run:

```bash
chmod +x update_dockerfiles.sh
./update_dockerfiles.sh
```

This replaces the `# --- COMMON HARDENING START ---` to `# --- COMMON HARDENING END ---` blocks in all targeted `Dockerfile.hardened` files.

### 2. Checking Image Update Status
To check if a specific image needs an upstream version or OS package update:

```bash
chmod +x check_update.sh
./check_update.sh ghcr.io/charlotte-de-r/hardening/vaultwarden:hardened
```

### 3. Manual Workflow Trigger
Workflows can be manually triggered from GitHub Actions tab (`workflow_dispatch`). Enabling `force_build: true` forces all container images to rebuild regardless of update detection.
