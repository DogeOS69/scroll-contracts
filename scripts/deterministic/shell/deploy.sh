#!/bin/sh

# Unsupported for DogeOS. This script deployed the Scroll L1 contracts
# (including L1ScrollMessenger and its Merkle withdrawal relay) and then the L2
# contracts. DogeOS has no Ethereum L1 bridge contracts: withdrawals are paid on
# Dogecoin, and the L2 withdrawal queue is a hash chain that the L1 relay could
# never verify. Use the production entrypoint docker/scripts/deploy.sh, which
# only simulates L1 and broadcasts the L2 bootstrap.

echo "scripts/deterministic/shell/deploy.sh is not supported for DogeOS: it deploys" >&2
echo "the Scroll L1 bridge contracts, which DogeOS does not use." >&2
echo "Use docker/scripts/deploy.sh (L2 bootstrap only); see README.md." >&2
exit 1
