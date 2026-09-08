import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts" / "validate_results.py"


class ValidateResultsTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.work = Path(self.temp_dir.name)

    @staticmethod
    def valid_metrics(completed=2):
        return {
            "duration": 1.25,
            "completed": completed,
            "request_throughput": 1.6,
            "mean_ttft_ms": 10.0,
            "mean_tpot_ms": 2.0,
            "mean_itl_ms": 1.5,
        }

    def run_validator(self, metrics, profile="probe", config_kind="upstream_generic_mock"):
        metrics_path = self.work / "metrics.json"
        summary_path = self.work / "validation.json"
        metrics_path.write_text(json.dumps(metrics) + "\n", encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--metrics",
                str(metrics_path),
                "--profile",
                profile,
                "--config-kind",
                config_kind,
                "--output",
                str(summary_path),
            ],
            text=True,
            capture_output=True,
        )
        summary = json.loads(summary_path.read_text()) if summary_path.exists() else None
        return result, summary

    def assert_rejected(self, metrics, profile="probe"):
        result, _ = self.run_validator(metrics, profile=profile)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("validation failed:", result.stderr)

    def test_accepts_pinned_hisim_schema_and_writes_normalized_summary(self):
        result, summary = self.run_validator(self.valid_metrics())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            summary,
            {
                "status": "PASS",
                "profile": "probe",
                "completed": 2,
                "failed": 0,
                "metrics": {
                    "duration_s": 1.25,
                    "request_throughput_req_s": 1.6,
                    "ttft_ms": 10.0,
                    "tpot_ms": 2.0,
                    "itl_ms": 1.5,
                },
                "config_kind": "upstream_generic_mock",
                "calibration_status": "NOT_CALIBRATED",
            },
        )

    def test_accepts_small_profile_with_sixteen_completions(self):
        result, summary = self.run_validator(self.valid_metrics(16), profile="small")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(summary["completed"], 16)
        self.assertEqual(summary["failed"], 0)

    def test_rejects_missing_required_metric(self):
        metrics = self.valid_metrics()
        del metrics["mean_itl_ms"]
        self.assert_rejected(metrics)

    def test_rejects_negative_metric(self):
        metrics = self.valid_metrics()
        metrics["mean_tpot_ms"] = -0.01
        self.assert_rejected(metrics)

    def test_rejects_nan_metric(self):
        metrics = self.valid_metrics()
        metrics["mean_ttft_ms"] = float("nan")
        self.assert_rejected(metrics)

    def test_rejects_infinite_metric(self):
        metrics = self.valid_metrics()
        metrics["request_throughput"] = float("inf")
        self.assert_rejected(metrics)

    def test_rejects_failed_requests(self):
        metrics = self.valid_metrics()
        metrics["failed"] = 1
        self.assert_rejected(metrics)

    def test_rejects_wrong_probe_completion_count(self):
        self.assert_rejected(self.valid_metrics(1))

    def test_rejects_wrong_small_completion_count(self):
        self.assert_rejected(self.valid_metrics(15), profile="small")

    def test_rejects_generic_result_labeled_calibrated(self):
        metrics = self.valid_metrics()
        metrics["calibration_status"] = "CALIBRATED"
        self.assert_rejected(metrics)

    def test_rejects_generic_result_labeled_as_h20_performance(self):
        metrics = self.valid_metrics()
        metrics["config_kind"] = "h20_performance"
        self.assert_rejected(metrics)

    def test_rejects_multiple_jsonl_records(self):
        metrics_path = self.work / "metrics.json"
        summary_path = self.work / "validation.json"
        line = json.dumps(self.valid_metrics())
        metrics_path.write_text(f"{line}\n{line}\n", encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--metrics",
                str(metrics_path),
                "--profile",
                "probe",
                "--config-kind",
                "upstream_generic_mock",
                "--output",
                str(summary_path),
            ],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("validation failed:", result.stderr)


if __name__ == "__main__":
    unittest.main()
