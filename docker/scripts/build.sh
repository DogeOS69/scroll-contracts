#!/bin/sh

latest_commit=$(git log -1 --pretty=format:%H)
tag=${latest_commit}
REPO="shuunifra/scroll-stack-contracts"
echo "Using Docker image tag: $tag"
echo ""

docker buildx build -f docker/Dockerfile.gen-configs -t $REPO:gen-configs-$tag --platform linux/amd64,linux/arm64 --push .
echo
echo "built $REPO:gen-configs-$tag"
echo

docker buildx build -f docker/Dockerfile.deploy -t $REPO:deploy-$tag --platform linux/amd64,linux/arm64 --push .
echo
echo "built $REPO:deploy-$tag"
echo

docker buildx build -f docker/Dockerfile.verify -t $REPO:verify-$tag --platform linux/amd64,linux/arm64 --push .
echo
echo "built $REPO:verify-$tag"
echo
