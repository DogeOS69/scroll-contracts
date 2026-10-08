#!/usr/bin/env python3
"""Read-only EIP-2935 smoke check at fixed L2 block heights (Python 3 stdlib)."""

import argparse
import json
import urllib.request

ADDRESS = "0x0000f90827f1c53a10cb7a02335b175320002935"
CODE = (
    "0x3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f"
    "35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f"
    "5ffd5b5f35611fff60014303065500"
)
ZERO = "0x" + "00" * 32
WINDOW = 8191


def rpc(url, method, params):
    request = urllib.request.Request(
        url,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError(f"{method}: {result['error']}")
    if result.get("result") is None:
        raise RuntimeError(f"{method}: missing result; block/state may be unavailable")
    return result["result"]


def check(url, height, activation):
    tag = hex(height)
    block = rpc(url, "eth_getBlockByNumber", [tag, False])
    if rpc(url, "eth_getCode", [ADDRESS, tag]).lower() != CODE:
        raise RuntimeError(f"block {height}: noncanonical or missing history runtime")
    if int(rpc(url, "eth_getTransactionCount", [ADDRESS, tag]), 16) != 1:
        raise RuntimeError(f"block {height}: history account nonce is not 1")
    # Check newest, oldest retained, and the unfilled slot before activation.
    numbers = {height - 1, max(0, height - WINDOW)}
    if activation > 1 and activation - 2 >= max(0, height - WINDOW):
        numbers.add(activation - 2)
    for number in sorted(numbers):
        expected = ZERO
        if number >= activation - 1:
            expected = rpc(url, "eth_getBlockByNumber", [hex(number), False])["hash"].lower()
        data = "0x" + number.to_bytes(32, "big").hex()
        actual = rpc(url, "eth_call", [{"to": ADDRESS, "data": data}, tag]).lower()
        storage = rpc(url, "eth_getStorageAt", [ADDRESS, hex(number % WINDOW), tag]).lower()
        if actual != expected or storage != expected:
            raise RuntimeError(f"block {height}, query {number}: history does not match L2 block hash")
    return block["hash"], block["stateRoot"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rpc_urls", nargs="+", help="one or more clients following the same L2 chain")
    parser.add_argument("--block", type=int, required=True, help="fixed block height with retained RPC state")
    parser.add_argument("--activation-block", type=int, default=1, help="first block that writes history (default: 1)")
    args = parser.parse_args()
    if not 1 <= args.activation_block <= args.block:
        parser.error("require 1 <= activation-block <= block")
    baseline = None
    for index, url in enumerate(args.rpc_urls):
        result = check(url, args.block, args.activation_block)
        if baseline is not None and result != baseline:
            raise RuntimeError("clients disagree on block hash or state root")
        baseline = result
        print(f"client {index + 1}: block {args.block} history OK; hash={result[0]} stateRoot={result[1]}")


if __name__ == "__main__":
    main()
