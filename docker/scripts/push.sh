#!/bin/sh
set -e # Exit immediately if a command exits with a non-zero status.

IMAGE_REPO="shuunifra/scroll-stack-contracts"
latest_commit=$(git log -1 --pretty=format:%h)
tag=${latest_commit:0:8}

echo "Using Docker image tag base: $tag for repo: $IMAGE_REPO"
echo ""

# --- Process gen-configs image ---
echo "Processing: gen-configs"
docker push "${IMAGE_REPO}:gen-configs-${tag}"
echo "Done for gen-configs-${tag}"
echo ""

# --- Process deploy image ---
echo "Processing: deploy"
docker push "${IMAGE_REPO}:deploy-${tag}"
echo "Done for deploy-${tag}"
echo ""

echo "Processing: verify"
docker push "${IMAGE_REPO}:verify-${tag}"
echo "Done for verify-${tag}"
echo ""

echo "Script finished successfully."
