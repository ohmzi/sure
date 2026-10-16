"""The sidecar gives the GPU back when it has been idle (spec §3): PaddleOCR
held ~2 GB of VRAM forever after the first document."""
import unittest
from unittest import mock

import app


class IdleReleaseTest(unittest.TestCase):
    def setUp(self):
        app._engine = object()
        app._last_used = 1000.0

    def tearDown(self):
        app._engine = None

    def test_an_engine_idle_past_the_limit_is_released(self):
        with mock.patch.object(app, "IDLE_RELEASE_SECONDS", 300), mock.patch.object(app, "free_gpu_cache") as free:
            self.assertTrue(app.release_if_idle(now=1301.0))
        self.assertIsNone(app._engine)
        free.assert_called_once()

    def test_a_recently_used_engine_is_kept(self):
        with mock.patch.object(app, "IDLE_RELEASE_SECONDS", 300):
            self.assertFalse(app.release_if_idle(now=1200.0))
        self.assertIsNotNone(app._engine)

    def test_a_read_in_progress_is_never_released(self):
        with mock.patch.object(app, "IDLE_RELEASE_SECONDS", 300), app._lock:
            self.assertFalse(app.release_if_idle(now=9999.0))
        self.assertIsNotNone(app._engine)

    def test_zero_disables_the_release(self):
        with mock.patch.object(app, "IDLE_RELEASE_SECONDS", 0):
            self.assertFalse(app.release_if_idle(now=9999.0))
        self.assertIsNotNone(app._engine)


if __name__ == "__main__":
    unittest.main()
