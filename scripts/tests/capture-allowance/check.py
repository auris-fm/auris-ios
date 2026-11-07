"""Actual child-death and flock controls. No claim about power-loss persistence."""
import hashlib
import json
import pathlib
import selectors
import subprocess
import sys
import tempfile

probe = str(pathlib.Path(sys.argv[1]).resolve())
receipts = []

def command(root, records=1, phase='none', mode='normal', account='synthetic', window='established-one', operation='charge'):
    return [probe, str(root), account, window, str(records), '100000', phase, mode, operation]

def run(root, **kwargs):
    result = subprocess.run(command(root, **kwargs), capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, (result.returncode, result.stderr)
    return result.stdout.strip()

def usage(root):
    path = root / hashlib.sha256(b'synthetic').hexdigest() / 'usage.json'
    return json.loads(path.read_text())['payload']['records']

def held(root):
    child = subprocess.Popen(command(root, phase='claimDurable', mode='hold', operation='provision'), stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    try:
        assert selector.select(timeout=5), 'claim barrier was not reached'
        assert child.stdout.readline().strip() == 'BARRIER:claimDurable'
        assert run(root) == 'REFUSED', 'second process acquired held initializer'
        inode = next(root.glob('*/claim.lock')).stat().st_ino
        output, error = child.communicate('x', timeout=5)
        assert child.returncode == 0 and output.strip() == 'PROVISIONED', (output, error)
        assert next(root.glob('*/claim.lock')).stat().st_ino == inode
        assert run(root) == 'CHARGED' and usage(root) == 1
        assert run(root) == 'REFUSED'
    finally:
        selector.close()
        if child.poll() is None:
            child.kill()
            child.communicate(timeout=5)

def established_contention(root):
    assert run(root, operation='provision') == 'PROVISIONED'
    child = subprocess.Popen(command(root, phase='intentDurable', mode='hold'), stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    try:
        assert selector.select(timeout=5), 'established charge barrier was not reached'
        assert child.stdout.readline().strip() == 'BARRIER:intentDurable'
        directory = root / hashlib.sha256(b'synthetic').hexdigest()
        before = {p.name: p.read_bytes() for p in directory.iterdir()}
        assert run(root) == 'REFUSED'
        after = {p.name: p.read_bytes() for p in directory.iterdir()}
        assert before == after, 'contending process mutated established accounting without the lock'
        output, error = child.communicate('x', timeout=5)
        assert child.returncode == 0 and output.strip() == 'CHARGED', (output, error)
        assert usage(root) == 1 and run(root) == 'REFUSED'
    finally:
        selector.close()
        if child.poll() is None:
            child.kill()
            child.communicate(timeout=5)

with tempfile.TemporaryDirectory(prefix='capture-allowance-control-') as temporary:
    base = pathlib.Path(temporary)
    for phase in ['claimDurable', 'genesisInitializing', 'initialUsage', 'genesisEstablished',
                  'intentDurable', 'usageRenamed', 'usageDurable', 'intentSettled']:
        for budget in [1, 2]:
            root = base / (phase + str(budget))
            initialization = phase in ['claimDurable', 'genesisInitializing', 'initialUsage', 'genesisEstablished']
            if not initialization:
                assert run(root, records=budget, operation='provision') == 'PROVISIONED'
            crashed = subprocess.run(command(root, records=budget, phase=phase, mode='crash',
                                             operation='provision' if initialization else 'charge'),
                                     capture_output=True, text=True, timeout=5)
            assert crashed.returncode == 77 and crashed.stdout.strip() == 'BARRIER:' + phase
            result = run(root, records=budget)
            if phase in ['claimDurable', 'genesisInitializing', 'initialUsage']:
                assert result == 'REFUSED'
            elif phase == 'genesisEstablished':
                assert result == 'CHARGED' and usage(root) == 1
            else:
                assert result == ('REFUSED' if budget == 1 else 'CHARGED')
                assert usage(root) == budget, 'recovery and fresh charge were conflated'
            receipts.append(dict(phase=phase, budget=budget, crashExit=77, recovery=result))
    root = base / 'contention'
    held(root)
    receipts.append(dict(control='two-process initializer contention', result='pass'))
    established_contention(base / 'established-contention')
    receipts.append(dict(control='established second-process contention preserves all bytes', result='pass'))
    root = base / 'stable-account'
    assert run(root, operation='provision') == 'PROVISIONED'
    assert run(root) == 'CHARGED'
    assert run(root) == 'REFUSED'
    assert run(root, window='changed-window') == 'REFUSED'
    assert usage(root) == 1
    assert run(root, account='different-account') == 'REFUSED'
    assert run(root, account='different-account', operation='provision') == 'PROVISIONED'
    assert run(root, account='different-account') == 'CHARGED'
    receipts.append(dict(control='restart account isolation and changed-window refusal', result='pass'))
    import shutil
    shutil.rmtree(root)
    assert run(root) == 'REFUSED' and not root.exists()
    receipts.append(dict(control='complete ledger loss refuses ordinary reopen without creation', result='pass'))
print(json.dumps(receipts, indent=2))
