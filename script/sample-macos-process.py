#!/usr/bin/env python3
"""Stream macOS ps CPU/RSS observations for a PID and its current descendants."""
import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def positive_float(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError('must be finite and greater than zero')
    return number


def snapshot():
    result = subprocess.run(
        ['/bin/ps', '-A', '-ww', '-o', 'pid=,ppid=,%cpu=,rss=,stat=,lstart=,comm='],
        capture_output=True, text=True, timeout=5,
        env={**os.environ, 'LC_ALL': 'en_US.UTF-8'}, check=True)
    processes = {}
    for line in result.stdout.splitlines():
        fields = line.split(None, 10)
        if len(fields) != 11:
            raise ValueError('Unexpected ps row; refusing incomplete observations')
        pid, ppid, cpu, rss = fields[:4]
        processes[int(pid)] = {
            'pid': int(pid), 'ppid': int(ppid), 'cpu_percent_ps': float(cpu),
            'rss_kib': int(rss), 'state_ps': fields[4],
            'started_at_ps': ' '.join(fields[5:10]), 'executable': fields[10],
        }
    return processes


def descendants(processes, root_pid):
    children = {}
    for process in processes.values():
        children.setdefault(process['ppid'], []).append(process['pid'])
    selected, pending = set(), [root_pid]
    while pending:
        pid = pending.pop()
        if pid in selected:
            continue
        selected.add(pid)
        pending.extend(children.get(pid, []))
    return [processes[pid] for pid in sorted(selected) if not processes[pid]['state_ps'].startswith('Z')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--duration', type=positive_float, default=60, help='seconds (default 60)')
    parser.add_argument('--interval', type=positive_float, default=1, help='seconds (default 1)')
    parser.add_argument('--output', type=Path, required=True, help='new JSONL file; never overwritten')
    parser.add_argument('--scenario', required=True, help='operator-supplied scene label, not verified by this tool')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('this sampler uses macOS ps semantics and requires macOS')
    if args.pid <= 0:
        parser.error('--pid must be greater than zero')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        output = args.output.open('x', encoding='utf-8')
    except OSError as error:
        parser.error(str(error))

    def emit(record):
        record['utc'] = datetime.now(timezone.utc).isoformat()
        output.write(json.dumps(record, ensure_ascii=False, separators=(',', ':')) + '\n')
        output.flush()

    def interrupt(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    started = time.monotonic()
    identity = None
    count = 0
    reason, code = 'duration_complete', 0
    with output:
        emit({'event': 'metadata', 'schema_version': 1, 'root_pid': args.pid,
              'scenario': args.scenario, 'duration_seconds': args.duration,
              'interval_seconds': args.interval, 'platform': sys.platform,
              'cpu_semantics': 'macOS ps %cpu: decaying average over up to a minute of prior real time; not interval CPU usage; tree sum may exceed 100%',
              'rss_semantics': 'ps RSS in KiB; tree sum can count shared pages multiple times; not private memory',
              'not_measured': ['GPU', 'private_memory', 'system_commit'],
              'tree_semantics': 'current descendants each snapshot; stops when root exits or identity changes; short-lived or reparented descendants may be missed',
              'storage_semantics': 'one process snapshot in memory; JSONL flushed per record; no history accumulated'})
        try:
            while time.monotonic() - started < args.duration:
                processes = snapshot()
                root = processes.get(args.pid)
                if root is None or root['state_ps'].startswith('Z'):
                    reason = 'target_missing' if root is None and identity is None else 'root_exited'
                    code = 1 if identity is None else 0
                    break
                current_identity = (root['started_at_ps'], root['executable'])
                if identity is not None and current_identity != identity:
                    reason = 'root_identity_changed'
                    break
                identity = current_identity
                selected = descendants(processes, args.pid)
                emit({'event': 'sample', 'index': count,
                      'elapsed_seconds': round(time.monotonic() - started, 6),
                      'root_pid': args.pid, 'process_count': len(selected),
                      'cpu_percent_ps_sum': round(sum(p['cpu_percent_ps'] for p in selected), 3),
                      'rss_kib_sum': sum(p['rss_kib'] for p in selected), 'processes': selected})
                count += 1
                elapsed = time.monotonic() - started
                # Derive the next deadline directly; skip missed slots instead
                # of accumulating samples or spinning to catch up after slow ps.
                next_slot = max(count, math.floor(elapsed / args.interval) + 1)
                delay = min(next_slot * args.interval, args.duration) - elapsed
                if delay > 0:
                    time.sleep(delay)
        except KeyboardInterrupt:
            reason, code = 'interrupted', 130
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            reason, code = 'sampling_error', 2
            emit({'event': 'error', 'message': str(error)})
        emit({'event': 'end', 'reason': reason, 'samples': count,
              'elapsed_seconds': round(time.monotonic() - started, 6)})
    return code


if __name__ == '__main__':
    raise SystemExit(main())
