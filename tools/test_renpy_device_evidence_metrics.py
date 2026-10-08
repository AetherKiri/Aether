#!/usr/bin/env python3
"""Synthetic scientific fixtures for the mobile evidence gates, not gameplay.

These byte arrays are explicitly generated test data. No device, renderer,
provider, adb or XCUITest execution is substituted or claimed by these tests.
"""

from __future__ import annotations

import copy
import functools
import tempfile
import unittest
from pathlib import Path

from run_renpy_android_device_acceptance import (
    Failed, checkpoint_landmarks, image_stats, is_script_checkpoint, pixel,
    read_engine_log_file, require_engine_log, require_landmark_pixels, verify_landmark_pixels, verify_resumed_marker,
)


COLORS = {"start_ready": ("START", [40, 180, 210]),
          "post_text_ready": ("WAIT", [65, 106, 221]),
          "quit_ready": ("RESUMED", [235, 164, 64])}


def checkpoint(stage="start_ready"):
    name, rgb = COLORS[stage]
    return {"source": "renpy-script", "run_id": "synthetic-metric-fixture", "stage": stage,
            "details": {"logical_canvas": [960, 540], "button_bounds": [360, 222, 240, 96],
                        "button_rgbs": [[23, 52, 76], [37, 106, 136]],
                        "marker_bounds": [360, 350, 240, 40], "marker_name": name, "marker_rgb": rgb}}


@functools.lru_cache(maxsize=None)
def synthetic_native(stage="start_ready", button=True, hover=False):
    # Half-resolution RGB data exercises logical-to-native conversion as well
    # as the separate native-to-OS letterbox transform.
    width, height = 480, 270
    data = bytearray(width * height * 3)
    marker = COLORS[stage][1]
    for y in range(height):
        for x in range(width):
            lx, ly = 2 * x, 2 * y
            rgb = [20 + x * 135 // width, 25 + y * 165 // height,
                   45 + (x + y) * 105 // (width + height)]
            if button and 360 <= lx < 600 and 222 <= ly < 318:
                rgb = [37, 106, 136] if hover else [23, 52, 76]
                # A small high-contrast synthetic label exercises 1px sampling
                # tolerance without treating text as another flat background.
                if 418 <= lx < 542 and 254 <= ly < 282 and (x // 3) % 2:
                    rgb = [255, 255, 255]
            if 360 <= lx < 600 and 350 <= ly < 390:
                rgb = marker
                if 436 <= lx < 524 and 362 <= ly < 378 and (x // 3) % 2:
                    rgb = [255, 255, 255]
            start = (y * width + x) * 3
            data[start:start + 3] = bytes(rgb)
    return width, height, bytes(data), 3


def synthetic_os(native, frame, size=(960, 540), shift=(0, 0), color_offset=0):
    width, height = size
    box, viewport = frame["drawn_box"], frame["viewport_size"]
    data = bytearray(width * height * 3)
    for y in range(height):
        v = ((y + 0.5 - shift[1]) * viewport[1] / height - box[1]) / box[3]
        if not 0 <= v < 1:
            continue
        ny = min(native[1] - 1, int(v * native[1]))
        for x in range(width):
            u = ((x + 0.5 - shift[0]) * viewport[0] / width - box[0]) / box[2]
            if not 0 <= u < 1:
                continue
            nx = min(native[0] - 1, int(u * native[0]))
            rgb = pixel(native, nx, ny)
            start = (y * width + x) * 3
            data[start:start + 3] = bytes(min(255, max(0, c + color_offset)) for c in rgb)
    return width, height, bytes(data), 3


def legacy_global_fraction(native, screen, frame):
    # Reproduce the retained pre-existing 77-point whole-scene proof limit.
    box, viewport = frame["drawn_box"], frame["viewport_size"]
    matches = count = 0
    for iy in range(1, 8):
        for ix in range(1, 12):
            u, v = ix / 12, iy / 8
            expected = pixel(native, int(u * native[0]), int(v * native[1]))
            actual = pixel(screen, int((box[0] + u * box[2]) * screen[0] / viewport[0]),
                           int((box[1] + v * box[3]) * screen[1] / viewport[1]))
            matches += max(abs(a - b) for a, b in zip(expected, actual)) <= 24
            count += 1
    return matches, count


class EvidenceMetrics(unittest.TestCase):
    full_frame = {"drawn_box": [0, 0, 1280, 720], "viewport_size": [1280, 720]}

    def test_positive_dense_roi_with_label_and_color_tolerance(self):
        native = synthetic_native()
        screen = synthetic_os(native, self.full_frame, color_offset=12)
        metrics = verify_landmark_pixels(native, screen, self.full_frame, checkpoint())
        require_landmark_pixels(metrics)
        self.assertGreater(metrics["button"]["samples"], 700)
        self.assertGreater(metrics["marker"]["samples"], 300)
        self.assertEqual(metrics["button"]["fraction"], 1)

    def test_missing_entire_button_passes_global_but_fails_roi(self):
        native = synthetic_native()
        screen = synthetic_os(synthetic_native(button=False), self.full_frame)
        image_stats(native)
        image_stats(screen)
        matches, count = legacy_global_fraction(native, screen, self.full_frame)
        self.assertEqual((matches, count), (74, 77))
        self.assertGreater(matches / count, 0.70)
        metrics = verify_landmark_pixels(native, screen, self.full_frame, checkpoint())
        self.assertLess(metrics["button"]["fraction"], 0.10)
        with self.assertRaises(Failed):
            require_landmark_pixels(metrics)

    def test_native_and_os_both_missing_button_cannot_pass(self):
        native = synthetic_native(button=False)
        screen = synthetic_os(native, self.full_frame)
        metrics = verify_landmark_pixels(native, screen, self.full_frame, checkpoint())
        self.assertEqual(metrics["button"]["fraction"], 1)
        self.assertLess(metrics["button"]["native_expected_color_fraction"], 0.70)
        with self.assertRaises(Failed):
            require_landmark_pixels(metrics)

    def test_hover_button_remains_valid(self):
        native = synthetic_native(hover=True)
        metrics = verify_landmark_pixels(native, synthetic_os(native, self.full_frame), self.full_frame, checkpoint())
        self.assertGreaterEqual(metrics["button"]["native_expected_color_fraction"], 0.70)
        require_landmark_pixels(metrics)

    def test_stale_wait_marker_rejected_even_when_os_matches_native(self):
        stale = synthetic_native("post_text_ready")
        screen = synthetic_os(stale, self.full_frame)
        metrics = verify_landmark_pixels(stale, screen, self.full_frame, checkpoint("quit_ready"))
        self.assertEqual(metrics["marker"]["fraction"], 1)
        self.assertLess(metrics["marker"]["native_expected_color_fraction"], 0.70)
        with self.assertRaises(Failed):
            require_landmark_pixels(metrics)
        change = verify_resumed_marker(stale, checkpoint("post_text_ready"), stale, checkpoint("quit_ready"))
        self.assertEqual(change["fraction"], 0)

    def test_os_retaining_wait_pixels_after_native_resume_is_rejected(self):
        native = synthetic_native("quit_ready")
        screen = synthetic_os(synthetic_native("post_text_ready"), self.full_frame)
        metrics = verify_landmark_pixels(native, screen, self.full_frame, checkpoint("quit_ready"))
        self.assertLess(metrics["marker"]["fraction"], 0.30)
        with self.assertRaises(Failed):
            require_landmark_pixels(metrics)

    def test_actual_native_marker_change_is_required(self):
        waiting, resumed = synthetic_native("post_text_ready"), synthetic_native("quit_ready")
        change = verify_resumed_marker(waiting, checkpoint("post_text_ready"), resumed, checkpoint("quit_ready"))
        self.assertGreaterEqual(change["fraction"], change["required_fraction"])
        metrics = verify_landmark_pixels(resumed, synthetic_os(resumed, self.full_frame),
                                         self.full_frame, checkpoint("quit_ready"))
        require_landmark_pixels(metrics)

    def test_impostor_source_and_wrong_run_or_stage_are_not_checkpoints(self):
        real = checkpoint()
        self.assertTrue(is_script_checkpoint(real, "start_ready", "synthetic-metric-fixture"))
        impostor = copy.deepcopy(real)
        impostor["source"] = "host-observer"
        self.assertFalse(is_script_checkpoint(impostor, "start_ready", "synthetic-metric-fixture"))
        self.assertFalse(is_script_checkpoint(real, "quit_ready", "synthetic-metric-fixture"))
        self.assertFalse(is_script_checkpoint(real, "start_ready", "another-run"))
        with self.assertRaises(Failed):
            checkpoint_landmarks(impostor)

    def test_letterbox_and_noninteger_scale_with_one_os_pixel_shift(self):
        native = synthetic_native()
        cases = [({"drawn_box": [0, 75, 800, 450], "viewport_size": [800, 600]}, (641, 481)),
                 ({"drawn_box": [45.25, 49.5, 1189.5, 669.09375],
                   "viewport_size": [1280, 720]}, (767, 431))]
        for frame, size in cases:
            with self.subTest(frame=frame, size=size):
                screen = synthetic_os(native, frame, size, shift=(1, -1))
                require_landmark_pixels(verify_landmark_pixels(native, screen, frame, checkpoint()))

    def test_incorrect_letterbox_transform_cannot_pass(self):
        native = synthetic_native()
        frame = {"drawn_box": [0, 75, 800, 450], "viewport_size": [800, 600]}
        screen = synthetic_os(native, frame, (641, 481))
        wrong = {"drawn_box": [0, 0, 800, 600], "viewport_size": [800, 600]}
        with self.assertRaises(Failed):
            require_landmark_pixels(verify_landmark_pixels(native, screen, wrong, checkpoint()))

    def test_invalid_landmark_bounds_rejected(self):
        for field, value in (("logical_canvas", [0, 540]), ("logical_canvas", [float("nan"), 540]),
                             ("button_bounds", [900, 222, 240, 96]),
                             ("marker_bounds", [360, 350, 8, 40]), ("marker_rgb", [True, 180, 210]),
                             ("button_rgbs", []), ("button_rgbs", [[23, 52]]),
                             ("button_rgbs", [[23, 52, 76.5]]), ("button_rgbs", [[True, 52, 76]])):
            bad = copy.deepcopy(checkpoint())
            bad["details"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(Failed):
                checkpoint_landmarks(bad)

    def test_godot_integral_float_json_roundtrip_remains_valid(self):
        # Actual Godot JSON.parse_string -> JSON.stringify emits these numbers
        # as integral floats; the observer's captured checkpoint uses this shape.
        captured = copy.deepcopy(checkpoint())
        for key in ("logical_canvas", "button_bounds", "marker_bounds", "marker_rgb"):
            captured["details"][key] = [float(v) for v in captured["details"][key]]
        captured["details"]["button_rgbs"] = [[float(v) for v in rgb] for rgb in captured["details"]["button_rgbs"]]
        self.assertEqual(captured["details"], checkpoint()["details"])
        checkpoint_landmarks(captured)

    def test_dense_roi_threshold_remains_ninety_percent(self):
        native = synthetic_native()
        screen = synthetic_os(native, self.full_frame)
        altered = bytearray(screen[2])
        # Corrupt roughly 13% of the visible button's interior, enough to pass
        # a 70% ROI gate while failing the required 90% gate with actual pixels.
        for y in range(226, 314):
            for x in range(566, 600):
                offset = (y * screen[0] + x) * screen[3]
                altered[offset:offset + 3] = b"\xff\x00\xff"
        screen = (screen[0], screen[1], bytes(altered), screen[3])
        metrics = verify_landmark_pixels(native, screen, self.full_frame, checkpoint())
        self.assertGreater(metrics["button"]["fraction"], 0.70)
        self.assertLess(metrics["button"]["fraction"], 0.90)
        with self.assertRaises(Failed):
            require_landmark_pixels(metrics)


class EngineLogEvidence(unittest.TestCase):
    # Explicit synthetic diagnostic text, never an actual runtime pass.
    root = "/cloud/private/renpy-device-demo"
    attachment = ("[2026-10-08 12:00:00.000] [info] aetherkiri provider engine log attached: "
                  + root + "/aetherkiri-engine.log\n")

    def test_nonempty_fresh_game_log_without_native_errors(self):
        raw = (self.attachment + "[info] info [renpy-mobile] renderer initialized\n"
               "[info] info [renpy-mobile] cooperative_stop completed\n"
               "[error] error [another-runtime] unrelated diagnostic\n").encode()
        report = require_engine_log(raw, self.root)
        self.assertEqual(report["renpy_mobile_error_records"], 0)
        self.assertIn("void-shutdown-status-unavailable", report["verification"])

    def test_terminal_egl_thread_and_python_cleanup_errors_reject(self):
        diagnostics = ["error [renpy-mobile] Ren'Py terminal cleanup failed; retained runtime resources require a host application restart",
                       "error [renpy-mobile] Ren'Py private EGL context could not be made current (EGL error 0x300e); context-loss recovery is unavailable",
                       "error [renpy-mobile] Ren'Py failed to restore the host EGL context after a lifecycle call",
                       "error [renpy-mobile] Ren'Py lifecycle called from a different thread than init",
                       "error [renpy-mobile] cooperative_stop",
                       "error [renpy-mobile] Python cleanup exception with no special keywords",
                       "warning [renpy-mobile] Ren'Py terminal cleanup failed",
                       "warning [renpy-mobile] cooperative_stop"]
        for line in diagnostics:
            with self.subTest(line=line), self.assertRaises(Failed):
                require_engine_log((self.attachment + "[2026-10-08] [error] " + line + "\n").encode(), self.root)

    def test_empty_unreadable_or_wrong_game_log_rejects(self):
        for raw in (None, b"", b" \n", b"\xff", b"some other log", self.attachment.replace(self.root, "/cloud/older-game").encode()):
            with self.subTest(raw=raw), self.assertRaises(Failed):
                require_engine_log(raw, self.root)

    def test_real_file_read_requires_available_regular_log(self):
        with tempfile.TemporaryDirectory(prefix="renpy-synthetic-log-gate-") as temporary:
            directory = Path(temporary)
            with self.assertRaises(Failed):
                read_engine_log_file(directory / "missing.log")
            with self.assertRaises(Failed):
                read_engine_log_file(directory)
            path = directory / "synthetic-aetherkiri-engine.log"
            path.write_text(self.attachment)
            require_engine_log(read_engine_log_file(path), self.root)


if __name__ == "__main__":
    unittest.main(verbosity=2)
