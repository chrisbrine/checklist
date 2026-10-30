"""Focused template tests: no encoder, native player, app or service is launched."""
import csv
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("make_animation_takes", Path(__file__).resolve().parents[1] / "script/make_animation_takes.py")
takes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(takes)


class AnimationTakeFixtureTests(unittest.TestCase):
    def test_commands_and_intake_cover_all_rates_and_directions(self):
        with tempfile.TemporaryDirectory() as root, patch.object(takes.subprocess, "run") as run:
            output = Path(root) / "takes"
            count = takes.generate(output, ffmpeg="/mock/ffmpeg")
            with (output / "intake.tsv").open(newline="") as handle:
                rows = list(csv.DictReader(handle, delimiter="\t"))
            self.assertEqual(count, 24)
            self.assertEqual(len(rows), 24)
            self.assertEqual(run.call_count, 24)
            for rate in takes.FRAME_RATES:
                selected = [row for row in rows if row["take"] == f"encoded{rate}fps"]
                self.assertEqual([row["direction"] for row in selected], list(takes.DIRECTIONS))
            for call, row in zip(run.call_args_list, rows):
                command = call.args[0]
                rate = row["take"].removeprefix("encoded").removesuffix("fps")
                self.assertEqual(command[command.index("-framerate") + 1], rate)
                self.assertEqual(command[command.index("-frames:v") + 1], "8")
                self.assertIn("-an", command)
                self.assertIn("-n", command)
                self.assertEqual(command[-1], str(output / row["path"]))
                self.assertNotIn("frame_rate", row)
                self.assertEqual(row["character"], "SyntheticHero")
                self.assertTrue(call.kwargs["check"])
                self.assertEqual(call.kwargs["input"].count(b"P6\n256 256\n255\n"), 8)

    def test_item_rate_override_preserves_encoded_rate(self):
        with tempfile.TemporaryDirectory() as root, patch.object(takes.subprocess, "run") as run:
            output = Path(root) / "override"
            takes.generate(output, ffmpeg="/mock/ffmpeg", declared_frame_rate=8)
            with (output / "intake.tsv").open(newline="") as handle:
                rows = list(csv.DictReader(handle, delimiter="\t"))
            self.assertEqual({row["frame_rate"] for row in rows}, {"8"})
            self.assertEqual({call.args[0][call.args[0].index("-framerate") + 1] for call in run.call_args_list}, {"4", "8", "12"})

    def test_existing_directory_refused_before_encoder_or_manifest_write(self):
        with tempfile.TemporaryDirectory() as root, patch.object(takes.subprocess, "run") as run:
            output = Path(root)
            sentinel = output / "intake.tsv"
            sentinel.write_text("keep me")
            with self.assertRaises(FileExistsError):
                takes.generate(output, ffmpeg="/mock/ffmpeg")
            run.assert_not_called()
            self.assertEqual(sentinel.read_text(), "keep me")

    def test_numbered_frames_are_distinct_and_complete(self):
        stream = takes.numbered_frames(0)
        frame_length = len(b"P6\n256 256\n255\n") + 256 * 256 * 3
        self.assertEqual(len(stream), 8 * frame_length)
        self.assertEqual(len({stream[offset:offset + frame_length] for offset in range(0, len(stream), frame_length)}), 8)
        self.assertNotEqual(stream, takes.numbered_frames(7))

    def test_filename_and_rate_input_validation(self):
        for value in ("../escape", "has__delimiter", "has space"):
            with self.assertRaises(takes.argparse.ArgumentTypeError):
                takes.safe_token(value)
        for value in ("nan", "inf", "0", "241", "bad"):
            with self.assertRaises(takes.argparse.ArgumentTypeError):
                takes.frame_rate(value)
        self.assertEqual(takes.frame_rate("8"), 8)


if __name__ == "__main__":
    unittest.main()
