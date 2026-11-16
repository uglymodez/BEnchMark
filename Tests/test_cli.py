"""Exercise machine-readable reports and interruption without performance thresholds."""
import csv
import io
import json
import math
import signal
import statistics
import subprocess
import sys

binary = sys.argv[1]
base = [binary, '--max-mib', '1', '--samples', '3', '--seconds', '0.001']
result = subprocess.run(base + ['--format', 'json'], capture_output=True, text=True, check=True)
report = json.loads(result.stdout)
assert report['schema_version'] == 2 and report['method'] == 'MBM-2.0'
assert report['state'] in ('complete', 'partial')
operations = {p['operation'] for p in report['points']}
assert {'read', 'write', 'latency'} <= operations
assert len(report['points']) == 33 * len(operations)
for p in report['points']:
    assert math.isfinite(p['median']) and 0 < p['minimum'] <= p['median'] <= p['maximum']
    assert len(p['sample_values']) == p['samples'] == 3
    assert math.isclose(statistics.median(p['sample_values']), p['median'], abs_tol=1e-8)
    expected = statistics.pstdev(p['sample_values']) / statistics.mean(p['sample_values']) * 100
    assert math.isclose(expected, p['cv_percent'], abs_tol=1e-5)
    assert p['unit'] == ('ns/load' if p['operation'] == 'latency' else 'GB/s')
result = subprocess.run(base + ['--mode', 'latency', '--descending'], capture_output=True, text=True, check=True)
rows = list(csv.DictReader(io.StringIO('\n'.join(line for line in result.stdout.splitlines() if not line.startswith('#')))))
assert len(rows) == 33 and int(rows[0]['buffer_bytes']) == 1024*1024 and int(rows[-1]['buffer_bytes']) == 4096
assert all(r['unit'] == 'ns/load' and r['sample_3'] and not r['sample_4'] for r in rows)
assert '# state: complete' in result.stdout
for args in (['--samples', '0'], ['--samples', '10'], ['--seconds', 'nan'], ['--seconds', 'inf'],
             ['--seconds', '0'], ['--seconds', '2'], ['--max-mib', '0'], ['--max-mib', '1025'],
             ['--format', 'xml'], ['--profile', 'bad'], ['--mode', 'bad'], ['--samples']):
    r = subprocess.run([binary] + args, capture_output=True, text=True)
    assert r.returncode == 2 and not r.stdout, args
assert subprocess.run([binary, '--help'], capture_output=True).returncode == 0
# Wait for the first data record, then interrupt an in-progress run. Output must
# remain valid JSON and stop promptly even with a long per-point target.
p = subprocess.Popen([binary, '--mode', 'latency', '--max-mib', '64', '--seconds', '0.2', '--format', 'json'],
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
header = p.stdout.readline()
first = p.stdout.readline()  # emitted before the second record after first point
p.send_signal(signal.SIGINT)
p.wait(timeout=5)
tail = p.stdout.read()
p.stderr.read()
assert p.returncode == 130
partial = json.loads(header + first + tail)
assert partial['state'] == 'cancelled' and partial['points']
print('PASS: CLI JSON/CSV, raw statistics, descending sweep, argument errors, SIGINT')
