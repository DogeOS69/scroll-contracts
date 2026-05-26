#!/bin/bash

echo ""
echo "generating config-contracts.toml"
forge script scripts/deterministic/DeployScroll.s.sol:DeployScroll --sig "run(string,string)" "none" "write-config" || exit 1

echo ""
echo "updating genesis.yaml"
forge script scripts/deterministic/GenerateGenesis.s.sol:GenerateGenesis || exit 1

echo ""
echo "updating coordinator-api-config.yaml and coordinator-cron-config.yaml"
forge script scripts/deterministic/GenerateConfigs.s.sol:GenerateCoordinatorConfig || exit 1
