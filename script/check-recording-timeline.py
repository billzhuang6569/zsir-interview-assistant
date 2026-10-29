#!/usr/bin/env python3
"""Validate encoded 30 fps presentation timing; never infer pixel repeats from PTS."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import sys


def rational(value):
    if value is None or str(value) in ('N/A', '0/0'):
        return None
    return Fraction(str(value))


def timestamp(item, name, time_base):
    ticks = rational(item.get(name))
    return ticks * time_base if ticks is not None else rational(item.get(name + '_time'))


def validate(probe, fps=30, av_tolerance=Fraction(1, 10), require_zero_start=False):
    """Use exact rational ticks, allowing half a stream tick for PTS quantization.

    Frame duration may be omitted except for the last frame: stream duration_ts
    then establishes its end. Container duration is deliberately not substituted.
    """
    if fps <= 0 or av_tolerance < 0:
        raise ValueError('fps must be positive and A/V tolerance nonnegative')
    streams = probe.get('streams', [])
    videos = [s for s in streams if s.get('codec_type') == 'video']
    errors, reports, audios = [], [], []
    if not videos:
        errors.append('No video stream')
    frames = probe.get('frames', [])
    for stream in videos:
        index = stream['index']
        prefix = f'video:{index}'
        tb = rational(stream.get('time_base'))
        if tb is None or tb <= 0 or tb > Fraction(1, fps):
            errors.append(f'{prefix}: missing or insufficient timestamp resolution')
            continue
        selected = [f for f in frames if f.get('media_type') == 'video' and f.get('stream_index') == index]
        if not selected:
            errors.append(f'{prefix}: no decoded frames')
            continue
        pts = [timestamp(f, 'pts', tb) for f in selected]
        if any(p is None for p in pts):
            errors.append(f'{prefix}: missing frame presentation timestamp')
            continue
        # ffprobe emits decoded presentation order. Do not sort: that hides errors.
        origin = pts[0]
        if require_zero_start and abs(origin) > tb / 2:
            errors.append(f'{prefix}: first-frame offset violates zero-start contract')
        for n, p in enumerate(pts):
            if abs(p - origin - Fraction(n, fps)) > tb / 2:
                errors.append(f'{prefix}: frame {n} PTS {float(p):.9f} differs from first PTS + n/{fps}')
                break
        if any(b <= a for a, b in zip(pts, pts[1:])):
            errors.append(f'{prefix}: non-increasing presentation timestamps')
        for n, frame in enumerate(selected):
            duration = timestamp(frame, 'duration', tb)
            if duration is None:
                duration = timestamp(frame, 'pkt_duration', tb)
            if duration is not None and (duration <= 0 or abs(duration - Fraction(1, fps)) > tb):
                errors.append(f'{prefix}: frame {n} has non-CFR duration')
                break
        last = selected[-1]
        last_duration = timestamp(last, 'duration', tb)
        if last_duration is None:
            last_duration = timestamp(last, 'pkt_duration', tb)
        stream_duration = timestamp(stream, 'duration_ts', tb)
        if stream_duration is None:
            stream_duration = rational(stream.get('duration'))
        start = timestamp(stream, 'start_pts', tb)
        if start is None:
            start = rational(stream.get('start_time'))
        if start is None:
            start = pts[0]
        expected_duration = Fraction(len(selected), fps)
        expected_end = origin + expected_duration
        end = pts[-1] + last_duration if last_duration is not None else None
        if stream_duration is not None:
            stream_end = start + stream_duration
            if abs(stream_end - expected_end) > tb:
                errors.append(f'{prefix}: stream duration/count mismatch')
            if end is None:
                end = stream_end
        if end is None:
            errors.append(f'{prefix}: cannot establish last frame end')
        elif abs(end - expected_end) > tb:
            errors.append(f'{prefix}: last frame end/count mismatch')
        for key in ('nb_frames', 'nb_read_frames'):
            count = rational(stream.get(key))
            if count is not None and count != len(selected):
                errors.append(f'{prefix}: {key} disagrees with decoded count')
        reports.append({'stream_index': index, 'decoded_frames': len(selected),
                        'start_seconds': float(pts[0]),
                        'end_seconds': float(end) if end is not None else None,
                        'expected_duration_seconds': float(expected_duration),
                        'first_frame_offset_seconds': float(origin),
                        'time_base': str(tb), 'width': stream.get('width'), 'height': stream.get('height')})
    for stream in streams:
        if stream.get('codec_type') != 'audio':
            continue
        tb = rational(stream.get('time_base'))
        start = rational(stream.get('start_time'))
        duration = rational(stream.get('duration'))
        if tb is not None:
            start = timestamp(stream, 'start_pts', tb) if stream.get('start_pts') is not None else start
            duration = timestamp(stream, 'duration_ts', tb) if stream.get('duration_ts') is not None else duration
        if start is None or duration is None:
            errors.append(f"audio:{stream['index']}: cannot establish A/V bounds")
            continue
        audio = {'stream_index': stream['index'], 'start_seconds': float(start), 'end_seconds': float(start + duration)}
        audios.append(audio)
        for video in reports:
            if video['end_seconds'] is None:
                continue
            if abs(float(start) - video['start_seconds']) > float(av_tolerance) or abs(float(start + duration) - video['end_seconds']) > float(av_tolerance):
                errors.append(f"audio:{stream['index']}: A/V boundary difference exceeds tolerance for video:{video['stream_index']}")
    return {'passed': not errors, 'errors': errors, 'video': reports, 'audio': audios,
            'fps': fps, 'av_boundary_tolerance_seconds': float(av_tolerance),
            'limits': ['CFR is checked relative to the first PTS; first_frame_offset_seconds reports an initial gap. Use --require-zero-start for the product zero-origin contract.',
                       'PTS cannot identify repeated pixel content or distinguish static capture from synthetic repeats; compare per-Take counters and visual motion evidence.',
                       'Audio checks compare stream boundaries only, not audible sync, internal gaps, sample integrity, or clock drift.',
                       'No audio stream is required unless --require-audio is supplied; selected tracks must be checked against the Take report.',
                       'Decode frames are inspected by ffprobe; this is not a full independent audio/video corruption or device acceptance test.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('recording', type=Path)
    parser.add_argument('--fps', type=int, default=30)
    parser.add_argument('--av-tolerance', type=Fraction, default=Fraction(1, 10), help='A/V boundary tolerance in seconds (default 0.1)')
    parser.add_argument('--require-audio', action='store_true')
    parser.add_argument('--require-zero-start', action='store_true', help='Also enforce the product zero-origin contract; CFR alone permits a first-frame offset')
    parser.add_argument('--ffprobe', default='ffprobe')
    args = parser.parse_args()
    try:
        result = subprocess.run([args.ffprobe, '-v', 'error', '-show_streams', '-show_frames', '-count_frames', '-of', 'json', str(args.recording.resolve())], capture_output=True, text=True, check=True)
        report = validate(json.loads(result.stdout), args.fps, args.av_tolerance, args.require_zero_start)
        if result.stderr.strip():
            report['errors'].append('ffprobe decode diagnostics: ' + result.stderr.strip())
        if args.require_audio and not report['audio']:
            report['errors'].append('Required audio stream missing or unmeasurable')
        report['passed'] = not report['errors']
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        report = {'passed': False, 'errors': [str(error)]}
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
