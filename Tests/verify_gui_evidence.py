"""Independently recompute GUI results from counters + elapsed time, not summaries."""
import csv
import json
import math
import statistics
import sys
from pathlib import Path

root = Path(sys.argv[1])
for name in ('memory-lab', 'memory-lab-ranges', 'memory-lab-read', 'memory-lab-write'):
    report = json.loads((root / (name + '.json')).read_text())
    first = json.loads((root / (name + '-first.json')).read_text())
    assert report['metadata']['measurement_protocol'] == 'timing-audit-v1'
    assert report['metadata']['complete'] and first['metadata']['complete']
    assert report['metadata']['run_id'] != first['metadata']['run_id']
    assert report['points'] != first['points'], 'Repeat run must not reuse saved points'
    records = list(csv.DictReader(line for line in (root / (name + '.csv')).read_text().splitlines() if not line.startswith('#')))
    assert len(records) == len(report['points'])
    for run in (first, report):
        for p in run['points']:
            assert len(p['sample_seconds']) == len(p['sample_iterations']) == p['samples']
            assert sum(p['sample_iterations']) == p['iterations']
            assert math.isclose(sum(p['sample_seconds']), p['total_sample_seconds'], rel_tol=1e-12)
            block = p['block_bytes']
            units = ((p['buffer_bytes']-block)//p['stride_bytes']+1)*block if block else (1 if p['operation']=='latency' else p['buffer_bytes'])
            assert units == p['work_units_per_iteration']
            rates = []
            for seconds, iterations, value in zip(p['sample_seconds'], p['sample_iterations'], p['sample_values']):
                assert seconds > 0 and iterations > 0
                rate = seconds*1e9/iterations if p['operation']=='latency' else units*iterations/seconds/1e9
                assert math.isclose(rate, value, rel_tol=1e-12)
                rates.append(rate)
            assert math.isclose(statistics.mean(rates), p['mean'], rel_tol=1e-12)
            assert math.isclose(statistics.median(rates), p['median'], rel_tol=1e-12)
    for p, c in zip(report['points'], records):
        assert int(c['work_units_per_iteration']) == p['work_units_per_iteration']
        for i, (seconds, iterations) in enumerate(zip(p['sample_seconds'], p['sample_iterations']), 1):
            assert float(c[f'sample_{i}_seconds']) == seconds
            assert int(c[f'sample_{i}_iterations']) == iterations
    for row in report.get('block_summary', []):
        points = [p for p in report['points'] if p['block_bytes']==row['block_bytes']]
        linear = next(p['mean'] for p in points if p['stride_bytes']==p['block_bytes'])
        mean = statistics.mean(p['mean'] for p in points if p['stride_bytes']!=p['block_bytes'])
        assert math.isclose(row['efficiency_percent'], mean/linear*100, rel_tol=1e-12)
    assert (root / (name + '-samples.txt')).read_text().startswith('Исходные измерения')
    print('PASS independent timing evidence:', name, len(report['points']), 'points, two distinct runs')
