import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('timeline', Path(__file__).parents[1] / 'check-recording-timeline.py')
timeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timeline)


def fixture(count=30, scale=1000):
    # Quantized rational ticks intentionally alternate 33/34ms at 30fps.
    ticks = [round(n * scale / 30) for n in range(count + 1)]
    return {'streams': [{'index': 0, 'codec_type': 'video', 'time_base': f'1/{scale}',
                         'start_pts': 0, 'duration_ts': ticks[-1], 'nb_frames': str(count),
                         'avg_frame_rate': '29999/1000', 'r_frame_rate': '0/0'}],
            'frames': [{'media_type': 'video', 'stream_index': 0, 'pts': ticks[n],
                        'pkt_duration': ticks[n + 1] - ticks[n]} for n in range(count)]}


class TimelineTests(unittest.TestCase):
    def test_quantized_ticks_and_inexact_fps_metadata(self):
        self.assertTrue(timeline.validate(fixture())['passed'])

    def test_exact_frame_unit_time_base(self):
        self.assertTrue(timeline.validate(fixture(scale=30))['passed'])

    def test_last_frame_is_included_in_duration(self):
        data = fixture()
        data['streams'][0]['duration_ts'] = 967
        self.assertFalse(timeline.validate(data)['passed'])

    def test_missing_pts_and_no_video_fail(self):
        data = fixture()
        del data['frames'][4]['pts']
        self.assertFalse(timeline.validate(data)['passed'])
        self.assertFalse(timeline.validate({})['passed'])

    def test_gap_and_duplicate_timestamp_fail(self):
        for shift in (0, 2):
            data = fixture()
            data['frames'][10]['pts'] = data['frames'][9 + shift]['pts']
            self.assertFalse(timeline.validate(data)['passed'])

    def test_nonzero_origin_reports_gap_and_optional_contract_failure(self):
        data = fixture()
        for frame in data['frames']:
            frame['pts'] += 100
        data['streams'][0]['start_pts'] = 100
        report = timeline.validate(data)
        self.assertTrue(report['passed'])
        self.assertEqual(report['video'][0]['first_frame_offset_seconds'], 0.1)
        self.assertFalse(timeline.validate(data, require_zero_start=True)['passed'])

    def test_unknown_last_duration_requires_stream_end(self):
        data = fixture()
        for frame in data['frames']:
            del frame['pkt_duration']
        self.assertTrue(timeline.validate(data)['passed'])
        del data['streams'][0]['duration_ts']
        self.assertFalse(timeline.validate(data)['passed'])

    def test_bad_last_duration_and_reported_count_fail(self):
        data = fixture()
        data['frames'][-1]['pkt_duration'] = 1
        self.assertFalse(timeline.validate(data)['passed'])
        data = fixture()
        data['streams'][0]['nb_read_frames'] = '29'
        self.assertFalse(timeline.validate(data)['passed'])

    def test_audio_boundary_tolerance_and_limit(self):
        data = fixture()
        data['streams'].append({'index': 1, 'codec_type': 'audio', 'time_base': '1/48000', 'start_pts': 0, 'duration_ts': 48000})
        self.assertTrue(timeline.validate(data)['passed'])
        data['streams'][1]['duration_ts'] = 60000
        self.assertFalse(timeline.validate(data)['passed'])

    def test_too_coarse_ticks_fail(self):
        self.assertFalse(timeline.validate(fixture(scale=10))['passed'])

    def test_static_pixels_cannot_be_inferred(self):
        report = timeline.validate(fixture(1))
        self.assertTrue(report['passed'])
        self.assertIn('PTS cannot identify', report['limits'][1])


if __name__ == '__main__':
    unittest.main()
