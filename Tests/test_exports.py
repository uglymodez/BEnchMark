"""Independently check reports produced by actual native GUI runs."""
import csv
import io
import json
import math
import pathlib
import statistics
import sys

root = pathlib.Path(sys.argv[1])
reports = sorted(root.glob('memory-lab*.json'))
assert reports, 'No GUI reports'
for path in reports:
    data = json.loads(path.read_text())
    points = data['points']
    assert data['metadata']['complete'] in (True, 1)
    assert points
    rows = list(csv.DictReader(io.StringIO('\n'.join(
        x for x in path.with_suffix('.csv').read_text().splitlines() if not x.startswith('#')))))
    assert len(rows) == len(points)
    for p, row in zip(points, rows):
        values = p['sample_values']
        assert all(math.isfinite(x) and x > 0 for x in values)
        assert len(values) == p['samples']
        assert p['minimum'] == min(values) and p['maximum'] == max(values)
        assert math.isclose(p['median'], statistics.median(values), rel_tol=1e-10)
        assert math.isclose(p['mean'], statistics.mean(values), rel_tol=1e-10)
        assert math.isclose(p['cv_percent'], statistics.pstdev(values) / statistics.mean(values) * 100, rel_tol=1e-8, abs_tol=1e-9)
        assert math.isclose(float(row['median']), p['median'], rel_tol=1e-7, abs_tol=1e-8)
        assert int(row['block_bytes']) == p['block_bytes']
        assert int(row['access_gap_bytes']) == p['access_gap_bytes']
        if p['block_bytes']:
            block, gap, n = p['block_bytes'], p['access_gap_bytes'], p['buffer_bytes']
            addresses = range(0, n - block + 1, block + abs(gap))
            traffic = len(addresses) * block
            assert int(row['accessed_bytes_per_pass']) == traffic
            weighted_rate = traffic * p['iterations'] / p['total_sample_seconds'] / 1e9
            assert p['minimum'] * (1-1e-8) <= weighted_rate <= p['maximum'] * (1+1e-8)
    if 'block_summary' in data:
        gaps = set(range(-3072, 7169, 256)) | {-128, -64, -32, 32, 64, 128}
        assert {(p['block_bytes'], p['access_gap_bytes']) for p in points} == {(b, g) for b in (32, 64, 128, 256) for g in gaps}
        assert len(points) == 188 and len(data['block_summary']) == 4
        for summary in data['block_summary']:
            series = [p for p in points if p['block_bytes'] == summary['block_bytes']]
            medians = [p['median'] for p in series]
            linear = next(p['median'] for p in series if p['access_gap_bytes'] == 0)
            assert summary['minimum'] == min(medians) and summary['maximum'] == max(medians)
            assert math.isclose(summary['mean'], statistics.mean(medians), rel_tol=1e-10)
            assert math.isclose(summary['relative_speed_percent'], statistics.mean(medians) / linear * 100, rel_tol=1e-10)
    if 'range_summary' in data:
        assert len(data['range_summary']) == 5
        for summary in data['range_summary']:
            for op, stats in summary.items():
                if op == 'buffer_bytes':
                    continue
                point = next(p for p in points if p['buffer_bytes'] == summary['buffer_bytes'] and p['operation'] == op)
                assert math.isclose(stats['mean'], statistics.mean(point['sample_values']), rel_tol=1e-10)
    print(f'PASS: {path.name}, {len(points)} measured points, raw statistics and CSV agree')
