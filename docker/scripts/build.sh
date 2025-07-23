#!/bin/sh

latest_commit=$(git log -1 --pretty=format:%H)
tag=${latest_commit}

REPO="dogeos69/scroll-stack-contracts"
echo "Using Docker image tag: $tag"
echo ""

docker buildx build -f docker/Dockerfile.base -t $REPO:base-$tag --platform linux/amd64,linux/arm64 --push .
echo
echo
BASE_IMAGE=$REPO:base-$tag
echo "BASE_IMAGE: $BASE_IMAGE"

docker buildx build -f docker/Dockerfile.gen-configs -t $REPO:gen-configs-$tag --platform linux/amd64,linux/arm64 \
--build-arg BASE_IMAGE=$BASE_IMAGE \
--push .
echo
echo "built $REPO:gen-configs-$tag"
echo

docker buildx build -f docker/Dockerfile.deploy -t $REPO:deploy-$tag --platform linux/amd64,linux/arm64 \
--build-arg BASE_IMAGE=$BASE_IMAGE \
--push .
echo
echo "built $REPO:deploy-$tag"
echo

docker buildx build -f docker/Dockerfile.verify -t $REPO:verify-$tag --platform linux/amd64,linux/arm64 \
--build-arg BASE_IMAGE=$BASE_IMAGE \
--push .
echo
echo "built $REPO:verify-$tag"
echo
