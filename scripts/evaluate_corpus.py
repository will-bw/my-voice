#!/usr/bin/env python
"""Validate and summarize a private my-voice JSONL evaluation corpus.

This script never calls a provider and never invents missing samples. It reads
user-produced manifests/results and writes aggregate JSON to stdout.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path


def read_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {error.msg}") from error
            if not isinstance(value, dict):
                raise ValueError(f"{path}:{line_number}: each line must be an object")
            rows.append(value)
    return rows


def normalized(text: str) -> str:
    return unicodedata.normalize("NFKC", text).casefold().strip()


def edit_distance(left: str, right: str) -> int:
    previous = list(range(len(right) + 1))
    for left_index, left_value in enumerate(left, 1):
        current = [left_index]
        for right_index, right_value in enumerate(right, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[right_index] + 1,
                    previous[right_index - 1] + (left_value != right_value),
                )
            )
        previous = current
    return previous[-1]


def ratio_distance(left: str, right: str) -> float:
    reference = normalized(right)
    return edit_distance(normalized(left), reference) / max(1, len(reference))


def percentile(values: list[float], percent: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * percent
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def validate_manifest(rows: list[dict]) -> dict[str, dict]:
    if len(rows) < 100:
        raise ValueError(f"manifest needs at least 100 items; found {len(rows)}")
    by_id: dict[str, dict] = {}
    entity_labeled = 0
    for index, row in enumerate(rows, 1):
        sample_id = row.get("id")
        audio_path = row.get("audio_path")
        reference = row.get("reference_text")
        entities = row.get("entities", [])
        if not isinstance(sample_id, str) or not sample_id:
            raise ValueError(f"manifest row {index}: id must be a non-empty string")
        if sample_id in by_id:
            raise ValueError(f"manifest row {index}: duplicate id {sample_id!r}")
        if not isinstance(audio_path, str) or not audio_path:
            raise ValueError(f"manifest row {index}: audio_path must be a non-empty string")
        if not isinstance(reference, str) or not reference:
            raise ValueError(f"manifest row {index}: reference_text must be non-empty")
        if not isinstance(entities, list):
            raise ValueError(f"manifest row {index}: entities must be a list")
        for entity in entities:
            if not isinstance(entity, dict) or not isinstance(entity.get("text"), str) or not entity["text"]:
                raise ValueError(f"manifest row {index}: every entity needs non-empty text")
            if not isinstance(entity.get("type"), str) or not entity["type"]:
                raise ValueError(f"manifest row {index}: every entity needs non-empty type")
        if entities:
            entity_labeled += 1
        by_id[sample_id] = row
    if entity_labeled < 50:
        raise ValueError(f"at least 50 items must contain entity labels; found {entity_labeled}")
    return by_id


def validate_results(rows: list[dict], manifest: dict[str, dict]) -> None:
    required = ("id", "arm", "provider", "success", "latency_ms")
    seen: set[tuple[str, str, str]] = set()
    for index, row in enumerate(rows, 1):
        for key in required:
            if key not in row:
                raise ValueError(f"results row {index}: missing {key}")
        if row["id"] not in manifest:
            raise ValueError(f"results row {index}: unknown id {row['id']!r}")
        if not isinstance(row["arm"], str) or not row["arm"]:
            raise ValueError(f"results row {index}: arm must be a non-empty string")
        if not isinstance(row["provider"], str) or not row["provider"]:
            raise ValueError(f"results row {index}: provider must be a non-empty string")
        result_key = (row["id"], row["arm"], row["provider"])
        if result_key in seen:
            raise ValueError(
                f"results row {index}: duplicate id/arm/provider combination {result_key!r}"
            )
        seen.add(result_key)
        if not isinstance(row["success"], bool):
            raise ValueError(f"results row {index}: success must be boolean")
        if row["success"] and not isinstance(row.get("hypothesis"), str):
            raise ValueError(f"results row {index}: successful result needs hypothesis")


def groups_have_complete_coverage(
    groups: dict[tuple[str, str], list[dict]], manifest: dict[str, dict]
) -> bool:
    manifest_ids = set(manifest)
    return bool(groups) and all({row["id"] for row in rows} == manifest_ids for rows in groups.values())


def summarize_group(rows: list[dict], manifest: dict[str, dict]) -> dict:
    successful = [row for row in rows if row["success"]]
    latencies = [float(row["latency_ms"]) for row in successful]
    cers: list[float] = []
    edit_rates: list[float] = []
    entity_truth = 0
    entity_hits = 0
    predicted_entities = 0
    correct_predictions = 0

    for row in successful:
        reference = manifest[row["id"]]
        hypothesis = row["hypothesis"]
        cers.append(ratio_distance(hypothesis, reference["reference_text"]))
        if isinstance(row.get("final_text"), str):
            edit_rates.append(ratio_distance(hypothesis, row["final_text"]))
        reference_entities = {normalized(item["text"]) for item in reference.get("entities", [])}
        hypothesis_text = normalized(hypothesis)
        entity_truth += len(reference_entities)
        entity_hits += sum(entity in hypothesis_text for entity in reference_entities)
        predictions = {normalized(value) for value in row.get("predicted_entities", []) if isinstance(value, str)}
        predicted_entities += len(predictions)
        correct_predictions += len(predictions & reference_entities)

    def mean_field(name: str) -> float | None:
        values = [float(row[name]) for row in successful if isinstance(row.get(name), (int, float))]
        return statistics.fmean(values) if values else None

    false_attractions = sum(int(row.get("false_hotword_attractions", 0)) for row in successful)
    sent_hotwords = sum(int(row.get("hotword_count", 0)) for row in successful)
    return {
        "samples": len(rows),
        "success_rate": len(successful) / max(1, len(rows)),
        "cer": statistics.fmean(cers) if cers else None,
        "entity_recall": entity_hits / entity_truth if entity_truth else None,
        "entity_precision": correct_predictions / predicted_entities if predicted_entities else None,
        "hotword_false_attraction_rate": false_attractions / sent_hotwords if sent_hotwords else None,
        "final_edit_rate": statistics.fmean(edit_rates) if edit_rates else None,
        "latency_ms_p50": percentile(latencies, 0.50),
        "latency_ms_p95": percentile(latencies, 0.95),
        "cpu_seconds_mean": mean_field("cpu_seconds"),
        "peak_rss_mb_mean": mean_field("peak_rss_mb"),
        "energy_impact_mean": mean_field("energy_impact"),
        "network_bytes_mean": mean_field("network_bytes"),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    args = parser.parse_args()
    try:
        manifest_rows = read_jsonl(args.manifest)
        manifest = validate_manifest(manifest_rows)
        result_rows = read_jsonl(args.results)
        validate_results(result_rows, manifest)
        groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
        for row in result_rows:
            groups[(str(row["arm"]), str(row["provider"]))].append(row)
        report = {
            "manifest_items": len(manifest),
            "entity_labeled_items": sum(bool(row.get("entities")) for row in manifest_rows),
            "result_rows": len(result_rows),
            "complete_ids": len({row["id"] for row in result_rows}),
            "groups": {
                f"{arm}::{provider}": summarize_group(rows, manifest)
                for (arm, provider), rows in sorted(groups.items())
            },
            "parameter_freeze_allowed": groups_have_complete_coverage(groups, manifest),
        }
        json.dump(report, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    except (OSError, ValueError) as error:
        print(f"evaluation error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
