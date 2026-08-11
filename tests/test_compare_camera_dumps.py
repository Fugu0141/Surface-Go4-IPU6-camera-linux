import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "tools" / "compare-camera-dumps.py"
SPEC = importlib.util.spec_from_file_location("compare_camera_dumps", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class CompareCameraDumpsTest(unittest.TestCase):
    def test_exact_acpi_id_is_high_confidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            win = root / "windows"
            linux = root / "linux"
            win.mkdir()
            linux.mkdir()
            (win / "pnp.txt").write_text("ACPI\\INT347A camera OV8865", encoding="utf-8")
            (linux / "devices.txt").write_text("INT347A:00 DRIVER=ov8865", encoding="utf-8")

            match = MODULE.compare_component(
                MODULE.COMPONENTS[0], list(MODULE.iter_text(win)), win,
                list(MODULE.iter_text(linux)), linux,
            )

            self.assertEqual(match.confidence, "HIGH")
            self.assertIn("INT347A", match.windows_ids)
            self.assertIn("INT347A", match.linux_ids)

    def test_one_sided_evidence_is_low_confidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            win = root / "windows"
            linux = root / "linux"
            win.mkdir()
            linux.mkdir()
            (linux / "dmesg.txt").write_text("dw9714 4-000c bound", encoding="utf-8")

            match = MODULE.compare_component(
                MODULE.COMPONENTS[-1], list(MODULE.iter_text(win)), win,
                list(MODULE.iter_text(linux)), linux,
            )

            self.assertEqual(match.confidence, "LOW")


if __name__ == "__main__":
    unittest.main()
