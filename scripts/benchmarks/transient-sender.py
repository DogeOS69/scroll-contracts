#!/usr/bin/env python3
"""Compare compiled messenger implementations on a pinned, local-only Chikyu fork.
Inputs are solc --combined-json abi,bin artifacts (see docs/benchmarks/transient-sender.md).
Only Anvil receives transactions/state overrides. The public endpoint supplies read-only fork state.
Requires Python 3, cast and anvil. No wallet or private key is used.
"""
import argparse
import json
import pathlib
import socket
import subprocess
import time
import urllib.request

MESSENGER = '0xe9c53ca91528246e4e29304058b9d78d7999c96a'
MOAT = '0xb46985d56f57d138bfaa7acbae0de38dc3cfc00f'
TARGET = '0x1234567890abcdef1234567890abcdef12345678'
SOURCE = '0x' + '12' * 20
DEPOSIT_ID = '0x' + '12' * 32
NONCE = 987654321
IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
RELAYED = '0x4641df4a962071e12719d8c8c8e5ac7fc4d97b927346a3d7a335b1f7517e133c'


def cast(*args):
    return subprocess.check_output(['cast', *map(str, args)], text=True).strip()


def calldata(sig, *args):
    return cast('calldata', sig, *args)


def frames(trace):
    yield trace
    for child in trace.get('calls', []):
        yield from frames(child)


class Bench:
    def __init__(self, url):
        assert url.startswith('http://127.0.0.1:')
        self.url = url

    def rpc(self, method, *params):
        body = json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=params)).encode()
        request = urllib.request.Request(self.url, body, {'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.load(response)
        if 'error' in result:
            raise RuntimeError(result['error'])
        return result['result']

    def view(self, address, signature, *args):
        return self.rpc('eth_call', {'to': address, 'data': calldata(signature, *args)}, 'latest')

    def send(self, tx):
        tx_hash = self.rpc('eth_sendTransaction', dict(tx, gasPrice=hex(10**9)))
        for _ in range(200):
            receipt = self.rpc('eth_getTransactionReceipt', tx_hash)
            if receipt:
                return receipt
            time.sleep(.05)
        raise RuntimeError('local receipt timeout')

    def install(self, artifact_path, key, arguments, proxy):
        compiled = json.loads(pathlib.Path(artifact_path).read_text())
        code = compiled['contracts'][key]['bin']
        receipt = self.send({'from': self.rpc('eth_accounts')[0], 'data': '0x' + code + arguments[2:],
                             'gas': hex(5_000_000)})
        assert int(receipt['status'], 16) == 1
        address = receipt['contractAddress']
        self.rpc('anvil_setStorageAt', proxy, IMPL_SLOT, '0x' + address[2:].zfill(64))
        return cast('keccak', self.rpc('eth_getCode', address, 'latest'))

    def receiver(self, budget):
        # Loop until >= budget spent: GAS; DUP1 GAS SWAP1 SUB PUSH3 budget GT JUMPI.
        # The burner has 31-gas granularity; report observed cost, not its input threshold.
        code = '0x00' if budget == 0 else '0x5a5b805a900362' + f'{budget:06x}' + '1160015700'
        self.rpc('anvil_setCode', TARGET, code)

    def trace(self, tx, budget):
        self.receiver(budget)
        trace = self.rpc('debug_traceCall', tx, 'latest', {'tracer': 'callTracer', 'tracerConfig': {'withLog': True}})
        calls = list(frames(trace))
        target = next(c for c in calls if c.get('to', '').lower() == TARGET)
        delivered = not any(c.get('error') for c in calls) and any(
            log['topics'][0] == RELAYED for c in calls for log in c.get('logs', []))
        return dict(delivered=delivered, requested_burn=budget, recipient_entry_gas=int(target['gas'], 16),
                    recipient_gas_used=int(target['gasUsed'], 16), errors=[c['error'] for c in calls if c.get('error')])

    def measure(self, tx, budget):
        result = self.trace(tx, budget)
        steps = self.rpc('debug_traceCall', tx, 'latest', {'disableMemory': True, 'disableStorage': True})
        result['ordinary_net_gas_used'] = steps['gas']
        if not steps['failed']:
            last = steps['structLogs'][-1]
            assert last['op'] in ('RETURN', 'STOP')
            result['gross_gas_used'] = 200000 - last['gas']
        return result

    def boundary(self, tx):
        lo, hi = 75000, 150000
        assert self.trace(tx, lo)['delivered'] and not self.trace(tx, hi)['delivered']
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if self.trace(tx, mid)['delivered']:
                lo = mid
            else:
                hi = mid
        return self.measure(tx, lo), self.measure(tx, hi)

    def verify_credit(self, tx, budget):
        checkpoint = self.rpc('evm_snapshot')
        try:
            self.receiver(budget)
            before = int(self.rpc('eth_getBalance', TARGET, 'latest'), 16)
            receipt = self.send(tx)
            return dict(status=int(receipt['status'], 16), credited_wei=
                        int(self.rpc('eth_getBalance', TARGET, 'latest'), 16) - before)
        finally:
            assert self.rpc('evm_revert', checkpoint)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('before', 'after', 'moat', 'output'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--fork-url', default='https://rpc.testnet.dogeos.com')
    parser.add_argument('--block', type=int, default=8394120)
    args = parser.parse_args()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.with_suffix('.anvil.log').open('w') as log:
        process = subprocess.Popen(['anvil', '--fork-url', args.fork_url, '--fork-block-number', str(args.block),
                                    '--host', '127.0.0.1', '--port', str(port), '--hardfork', 'cancun',
                                    '--steps-tracing', '--silent'], stdout=log, stderr=log)
        try:
            for _ in range(240):
                if process.poll() is not None:
                    raise RuntimeError('Anvil failed; inspect its log')
                with socket.socket() as sock:
                    if sock.connect_ex(('127.0.0.1', port)) == 0:
                        break
                time.sleep(.25)
            else:
                raise RuntimeError('Anvil startup timeout')
            bench = Bench(f'http://127.0.0.1:{port}')
            block = bench.rpc('eth_getBlockByNumber', 'latest', False)
            assert int(block['number'], 16) == args.block
            counterpart = '0x' + bench.view(MESSENGER, 'counterpart()')[-40:]
            queue = '0x' + bench.view(MESSENGER, 'messageQueue()')[-40:]
            sender = hex((int(counterpart, 16) + int('1111000000000000000000000000000000001111', 16)) % 2**160)
            bench.rpc('anvil_setBalance', sender, hex(10**22))
            bench.rpc('anvil_impersonateAccount', sender)
            moat_hash = bench.install(args.moat, 'src/dogeos/Moat.sol:Moat',
                                     cast('abi-encode', 'f(bytes1,bytes1,address)', '0x71', '0xc4', MESSENGER), MOAT)
            assert int(bench.view(MOAT, 'depositFee()'), 16) == 10**18
            def tx(nonce):
                return {'from': sender, 'to': MESSENGER, 'gas': hex(200000), 'gasPrice': '0x0',
                        'data': calldata('relayMessage(address,address,uint256,uint256,bytes)', SOURCE, MOAT,
                                         10**19, nonce, calldata('handleL1Message(address,bytes32)', TARGET, DEPOSIT_ID))}
            result = dict(block=args.block, block_hash=block['hash'], moat_runtime_hash=moat_hash,
                          gas_limit=200000, transaction=tx(NONCE), cases=[])
            for label, artifact in [('before', args.before), ('after', args.after)]:
                for legacy in (True, False):
                    checkpoint = bench.rpc('evm_snapshot')
                    try:
                        code_hash = bench.install(artifact, 'src/dogeos/L2DogeOsMessenger.sol:L2DogeOsMessenger',
                                                  cast('abi-encode', 'f(address,address,address,bool)', counterpart,
                                                       queue, MOAT, str(legacy).lower()), MESSENGER)
                        for populated in (False, True):
                            if populated:
                                bench.receiver(0)
                                assert int(bench.send(tx(NONCE - 1))['status'], 16) == 1
                                assert int(bench.view(MESSENGER, 'isL1MessageNonceExecuted(uint256)', NONCE - 1), 16) == 1
                            maximum, failure = bench.boundary(tx(NONCE))
                            row = dict(version=label, legacy_replay_check=legacy, populated_word=populated,
                                       runtime_hash=code_hash, baseline=bench.measure(tx(NONCE), 0),
                                       max_success=maximum, min_failure=failure,
                                       burn_100k=bench.measure(tx(NONCE), 100000),
                                       credit_100k=bench.verify_credit(tx(NONCE), 100000))
                            assert bench.verify_credit(tx(NONCE), maximum['requested_burn'])['credited_wei'] == 9 * 10**18
                            assert bench.verify_credit(tx(NONCE), failure['requested_burn'])['credited_wei'] == 0
                            result['cases'].append(row)
                            print(label, 'legacy', legacy, 'populated', populated, maximum['recipient_gas_used'], flush=True)
                    finally:
                        assert bench.rpc('evm_revert', checkpoint)
            output.write_text(json.dumps(result, indent=2) + '\n')
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == '__main__':
    main()
