import copy
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_CONFIG = (
    ROOT
    / "third_party"
    / "tair-kvcache"
    / "hisim"
    / "test"
    / "assets"
    / "mock"
    / "config.qwen8b.aic.json"
)
H20_CONFIG = ROOT / "configs" / "h20-qwen3-8b.json"


class H20ConfigTest(unittest.TestCase):
    def test_preserves_pinned_upstream_contract_with_container_paths(self):
        upstream = json.loads(UPSTREAM_CONFIG.read_text(encoding="utf-8"))
        actual = json.loads(H20_CONFIG.read_text(encoding="utf-8"))

        expected = copy.deepcopy(upstream)
        expected["predictor"]["database_path"] = "/opt/hisim-data/aic"
        expected["predictor"]["xgb_model_path"] = (
            "/opt/hisim-data/aic/xgb_models/qwen3_8B"
        )
        self.assertEqual(actual, expected)

        self.assertEqual(actual["platform"]["accelerator"]["name"], "H20")
        self.assertEqual(actual["platform"]["disk_read_bandwidth_gb"], 4)
        self.assertEqual(actual["platform"]["disk_write_bandwidth_gb"], 4)
        self.assertEqual(actual["platform"]["memory_read_bandwidth_gb"], 64)
        self.assertEqual(actual["platform"]["memory_write_bandwidth_gb"], 64)
        self.assertEqual(actual["platform"]["num_device_per_node"], 8)

        self.assertEqual(actual["predictor"]["name"], "aiconfigurator")
        self.assertEqual(actual["predictor"]["device_name"], "h20_sxm")
        self.assertEqual(actual["predictor"]["prefill_scale_factor"], 1.045)
        self.assertEqual(actual["predictor"]["decode_scale_factor"], 1.0)
        self.assertEqual(actual["predictor"]["database_path"], "/opt/hisim-data/aic")
        self.assertEqual(
            actual["predictor"]["xgb_model_path"],
            "/opt/hisim-data/aic/xgb_models/qwen3_8B",
        )

        self.assertEqual(actual["scheduler"]["tp_size"], 1)
        self.assertEqual(actual["scheduler"]["data_type"], "FP16")
        self.assertEqual(actual["scheduler"]["kv_cache_data_type"], "FP16")
        self.assertEqual(actual["scheduler"]["backend_version"], "0.5.6.post2")


if __name__ == "__main__":
    unittest.main()
