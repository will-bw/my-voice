import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "evaluate_corpus.py"
SPEC = importlib.util.spec_from_file_location("evaluate_corpus", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class EvaluationToolTests(unittest.TestCase):
    def test_manifest_requires_real_scale_and_entity_coverage(self):
        with self.assertRaisesRegex(ValueError, "at least 100"):
            MODULE.validate_manifest([])

        rows = [
            {
                "id": f"sample-{index}",
                "audio_path": f"private/{index}.wav",
                "reference_text": "reference",
                "entities": [{"text": "Entity", "type": "term"}] if index < 49 else [],
            }
            for index in range(100)
        ]
        with self.assertRaisesRegex(ValueError, "at least 50"):
            MODULE.validate_manifest(rows)

    def test_summary_computes_accuracy_latency_and_resources(self):
        manifest = {
            "one": {
                "id": "one",
                "reference_text": "Ship Morrow",
                "entities": [{"text": "Morrow", "type": "project"}],
            }
        }
        summary = MODULE.summarize_group(
            [{
                "id": "one",
                "success": True,
                "hypothesis": "Ship Morrow",
                "final_text": "Ship Morrow",
                "predicted_entities": ["Morrow"],
                "latency_ms": 120,
                "cpu_seconds": 0.3,
                "peak_rss_mb": 80,
                "energy_impact": 2.0,
                "network_bytes": 0,
                "hotword_count": 2,
                "false_hotword_attractions": 0,
            }],
            manifest,
        )
        self.assertEqual(summary["cer"], 0)
        self.assertEqual(summary["entity_recall"], 1)
        self.assertEqual(summary["entity_precision"], 1)
        self.assertEqual(summary["latency_ms_p95"], 120)
        self.assertEqual(summary["peak_rss_mb_mean"], 80)

    def test_results_reject_duplicates_and_freeze_requires_every_group(self):
        manifest = {"one": {}, "two": {}}
        duplicate = {
            "id": "one",
            "arm": "baseline",
            "provider": "local",
            "success": False,
            "latency_ms": 10,
        }
        with self.assertRaisesRegex(ValueError, "duplicate id/arm/provider"):
            MODULE.validate_results([duplicate, duplicate.copy()], manifest)

        incomplete_groups = {
            ("baseline", "local"): [{"id": "one"}, {"id": "two"}],
            ("candidate", "cloud"): [{"id": "one"}],
        }
        self.assertFalse(MODULE.groups_have_complete_coverage(incomplete_groups, manifest))
        incomplete_groups[("candidate", "cloud")].append({"id": "two"})
        self.assertTrue(MODULE.groups_have_complete_coverage(incomplete_groups, manifest))


if __name__ == "__main__":
    unittest.main()
