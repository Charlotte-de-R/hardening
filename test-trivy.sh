#!/bin/bash
docker pull alpine:3.18
docker save alpine:3.18 > alpine.tar
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin v0.48.3
trivy image --input alpine.tar
