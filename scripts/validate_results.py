#!/usr/bin/env python3
"""Validate one pinned HiSim serving benchmark JSONL record.

Usage:
  validate_results.py --metrics METRICS.json --provenance PROVENANCE.json \
    --profile probe|small|sharegpt \
    --config-kind upstream_generic_mock|official_h20_data_path|sharegpt_workload_shape \
    --output validation.json
"""

import argparse
import json
import math
import sys
from pathlib import Path


EXPECTED_COMPLETED = {"probe": 2, "small": 16, "sharegpt": 16}
CALIBRATION_BY_KIND = {
    "upstream_generic_mock": "NOT_CALIBRATED",
    "official_h20_data_path": "INTEGRATION_ONLY",
    "sharegpt_workload_shape": "WORKLOAD_SHAPE_ONLY",
}
METRIC_FIELDS = {
    "duration_s": "duration",
    "request_throughput_req_s": "request_throughput",
    "ttft_ms": "mean_ttft_ms",
    "tpot_ms": "mean_tpot_ms",
    "itl_ms": "mean_itl_ms",
}
PROVENANCE_FIELDS = {
    "schema_version",
    "service_kind",
    "dataset_profile",
    "benchmark_profile",
    "expected_config_kind",
}
EXPECTED_PROVENANCE = {
    ("generic", "none", "probe"): "upstream_generic_mock",
    ("generic", "none", "small"): "upstream_generic_mock",
    ("h20", "none", "probe"): "official_h20_data_path",
    ("h20", "none", "small"): "official_h20_data_path",
    ("generic", "sharegpt", "sharegpt"): "sharegpt_workload_shape",
}


class ValidationError(ValueError):
    pass


def load_single_record(path):
    lines = [line for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]
    if len(lines) != 1:
        raise ValidationError(f"expected exactly one JSONL record, found {len(lines)}")
    try:
        record = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise ValidationError(f"invalid JSON: {error}") from error
    if not isinstance(record, dict):
        raise ValidationError("benchmark record must be a JSON object")
    return record


def load_provenance(path):
    try:
        provenance = json.loads(Path(path).read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ValidationError(f"invalid lifecycle provenance JSON: {error}") from error
    if not isinstance(provenance, dict):
        raise ValidationError("lifecycle provenance must be a JSON object")
    if set(provenance) != PROVENANCE_FIELDS:
        raise ValidationError("lifecycle provenance has missing or unexpected fields")
    if provenance["schema_version"] != 1:
        raise ValidationError("unsupported lifecycle provenance schema_version")
    key = (
        provenance["service_kind"],
        provenance["dataset_profile"],
        provenance["benchmark_profile"],
    )
    expected_kind = EXPECTED_PROVENANCE.get(key)
    if expected_kind is None or provenance["expected_config_kind"] != expected_kind:
        raise ValidationError("unsupported or inconsistent lifecycle provenance mapping")
    return provenance


def finite_nonnegative(record, field):
    if field not in record:
        raise ValidationError(f"missing required metric: {field}")
    value = record[field]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValidationError(f"metric {field} must be numeric")
    if not math.isfinite(value) or value < 0:
        raise ValidationError(f"metric {field} must be finite and nonnegative")
    return value


def validate(record, provenance, profile, config_kind):
    if config_kind not in CALIBRATION_BY_KIND:
        raise ValidationError(f"unsupported config kind: {config_kind}")
    expected_calibration = CALIBRATION_BY_KIND[config_kind]
    if provenance["benchmark_profile"] != profile:
        raise ValidationError("CLI profile does not match lifecycle provenance")
    if provenance["expected_config_kind"] != config_kind:
        raise ValidationError("CLI config kind does not match lifecycle provenance")

    expected = EXPECTED_COMPLETED[profile]
    completed = record.get("completed")
    if isinstance(completed, bool) or not isinstance(completed, int):
        raise ValidationError("completed must be an integer")
    if completed != expected:
        raise ValidationError(f"completed must equal {expected} for {profile}, got {completed}")

    explicit_failed = record.get("failed", 0)
    if isinstance(explicit_failed, bool) or not isinstance(explicit_failed, int):
        raise ValidationError("failed must be an integer when present")
    if explicit_failed != 0:
        raise ValidationError(f"failed requests must equal zero, got {explicit_failed}")

    if "config_kind" in record and record["config_kind"] != config_kind:
        raise ValidationError("result is labeled as a different config kind")
    if "calibration_status" in record and record["calibration_status"] != expected_calibration:
        raise ValidationError(
            f"{config_kind} result must be labeled {expected_calibration}"
        )

    normalized = {
        name: finite_nonnegative(record, source)
        for name, source in METRIC_FIELDS.items()
    }
    return {
        "status": "PASS",
        "profile": profile,
        "completed": completed,
        "failed": expected - completed,
        "metrics": normalized,
        "config_kind": config_kind,
        "calibration_status": expected_calibration,
    }


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metrics", required=True, type=Path)
    parser.add_argument("--provenance", required=True, type=Path)
    parser.add_argument("--profile", required=True, choices=sorted(EXPECTED_COMPLETED))
    parser.add_argument("--config-kind", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        summary = validate(
            load_single_record(args.metrics),
            load_provenance(args.provenance),
            args.profile,
            args.config_kind,
        )
    except (OSError, ValidationError) as error:
        print(f"validation failed: {error}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"validation passed: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
