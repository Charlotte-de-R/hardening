#!/bin/bash
curl -s "https://api.github.com/repos/github/codeql-action/commits/v3" | jq -r .sha
