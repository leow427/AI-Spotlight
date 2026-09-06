#!/usr/bin/env python3
"""Run opt-in, cold-start local-model measurements; never overwrite or discard attempts."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import os
import csv
from collections import Counter
from datetime import datetime, timezone
import hashlib


def response_correct(row):
    if row.get("task") != "ambiguous":
        return True
    text = row["trace"]["assistant_text"].lower()
    return row["changes"] == 0 and any(s in text for s in ("occurrence", "first", "second")) and any(
        s in text for s in ("which", "choose", "specif", "?"))


def completed_success(row):
    # Apply the same clarification criterion to older records without rewriting their raw scores.
    return row["success"] and response_correct(row)


def attempt_metrics(row):
    trace = row["trace"]
    diagnostics = trace["inference"]
    errors = [d for d in diagnostics if d.get("error")]
    if "controller" in trace:
        tool_errors = [e for e in trace["controller"] if e.get("success") is False or e.get("duplicate")]
    else:
        tool_errors = [m for m in trace["history"] if m["role"] == "tool" and
                       ("No change was made" in m["content"] or "Invalid structured" in m["content"])]
    clean = completed_success(row) and not errors and not tool_errors
    reason = row["error"] or ""
    if completed_success(row):
        kind = "success" if clean else "recovered_success"
    elif "context" in reason.lower():
        kind = "context_budget"
    elif any(d.get("finish_reason") == "length" for d in diagnostics):
        kind = "output_truncation"
    elif "step limit" in reason or "without progress" in reason:
        kind = "unproductive_loop"
    elif "failed edit" in reason or "arguments" in reason:
        kind = "tool_error"
    elif reason:
        kind = "runtime_or_terminal_tool_error"
    elif not response_correct(row):
        kind = "incorrect_clarification"
    elif not row["correct"]:
        kind = "incorrect_edit" if row["changes"] else "premature_completion"
    else:
        kind = "restoration_failure"
    return clean, kind, len(tool_errors), sum((d.get("usage") or {}).get("completion_tokens", 0) for d in diagnostics)


def summarize(paths, csv_path=None):
    groups = {}
    attempts = []
    for path in paths:
        rows = [json.loads(line) for line in Path(path).read_text().splitlines()]
        started = {r["id"] for r in rows if r.get("event") == "attempt_started"}
        finished = {r["id"] for r in rows if r.get("event") == "attempt_finished"}
        if started - finished:
            print(f"{path}: unfinished attempts (running or interrupted): {sorted(started - finished)}")
        for row in rows:
            if row.get("event") != "attempt_finished":
                continue
            key = (Path(path).name, row["context"], row["limit"])
            groups.setdefault(key, []).append(row)
            clean, kind, errors, tokens = attempt_metrics(row)
            diagnostics = row["trace"]["inference"]
            events = row["trace"].get("controller", [])
            attempts.append({"source": Path(path).name, "id": row["id"], "task": row["task"],
                "context": row["context"], "response_limit": row["limit"], "first_pass": int(clean),
                "recorded_success": int(row["success"]), "response_correct": int(response_correct(row)),
                "eventual_success": int(completed_success(row)), "correct_contents_and_format": int(row["correct"]),
                "undo_restored": int(row["undo_restored"]), "seconds": round(row["seconds"], 3),
                "inference_calls": len(diagnostics), "generated_tokens": tokens,
                "maximum_prompt_tokens": max((d.get("rendered_prompt_tokens", 0) for d in diagnostics), default=0),
                "maximum_response_tokens": max(((d.get("usage") or {}).get("completion_tokens", 0) for d in diagnostics), default=0),
                "finish_reasons": json.dumps(dict(Counter(d.get("finish_reason", "no_completion") for d in diagnostics)), sort_keys=True),
                "discarded_speculative_calls": sum(e.get("discarded_calls", 0) for e in events) if "controller" in row["trace"] else "",
                "response_recoveries": sum(e.get("event") in ("incomplete_recovery", "completion_recovery") for e in events),
                "fallback_notices": row["trace"].get("fallback_notices", ""),
                "tool_errors_or_duplicates": errors, "outcome": kind, "error": row["error"] or ""})
    print("File | Context | Limit | Runs | Clean success | Eventual success | Correct | Undo | Median seconds | Failures")
    for key, rows in groups.items():
        clean = 0
        failures = {}
        for row in rows:
            clean += attempt_metrics(row)[0]
            if not completed_success(row):
                reason = row["error"] or ("incorrect clarification" if not response_correct(row) else
                    "incorrect edit or formatting" if not row["correct"] else "Undo failure")
                failures[reason] = failures.get(reason, 0) + 1
        values = [*key, len(rows), clean, sum(completed_success(r) for r in rows), sum(r["correct"] for r in rows),
                  sum(r["undo_restored"] for r in rows), round(statistics.median(r["seconds"] for r in rows), 2), failures]
        print(" | ".join(map(str, values)))
    if csv_path and attempts:
        with Path(csv_path).open("x", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(attempts[0]), lineterminator="\n")
            writer.writeheader()
            writer.writerows(attempts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summarize", nargs="+")
    parser.add_argument("--csv", type=Path, help="Save one row for every recorded attempt (new path only)")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--phase", default="evaluation")
    parser.add_argument("--context", type=int, choices=[4096, 8192, 16384], default=8192)
    parser.add_argument("--limits", default="1024,2048,4096")
    parser.add_argument("--runs", type=int, default=20)
    tasks = parser.add_mutually_exclusive_group()
    tasks.add_argument("--matrix", action="store_true")
    tasks.add_argument("--held-out", action="store_true", help="Additional tasks not used to tune the controller")
    args = parser.parse_args()
    if args.summarize:
        summarize(args.summarize, args.csv)
        return
    if args.output is None or args.runs < 1 or any(int(x) not in (1024, 2048, 4096) for x in args.limits.split(",")):
        parser.error("Supply a new --output JSONL path, positive runs and limits 1024/2048/4096")
    output = args.output.absolute()
    log = output.with_suffix(".log")
    metadata = output.with_suffix(".metadata.json")
    if any(path.exists() for path in (output, log, metadata)):
        parser.error("Output, log or metadata already exists; choose a new path to retain earlier results")
    repository = Path(__file__).resolve().parent.parent
    sources = sorted((repository / "AI-Spotlight/Files").glob("*.swift")) + [
        repository / "AI-Spotlight/LocalInference/LlamaServerVisionEngine.swift",
        repository / "AI-SpotlightTests/FileModeRuntimeTests.swift"]
    with metadata.open("x") as stream:
        json.dump({"started_utc": datetime.now(timezone.utc).isoformat(),
            "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip(),
            "source_sha256": {str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}},
            stream, indent=2)
        stream.write("\n")
    environment = dict(os.environ)
    for key, value in {"OUTPUT": str(output), "PHASE": args.phase, "CONTEXT": args.context,
                       "LIMITS": args.limits, "RUNS": args.runs, "MATRIX": int(args.matrix),
                       "HELD_OUT": int(args.held_out)}.items():
        environment["TEST_RUNNER_AI_SPOTLIGHT_FILE_EVAL_" + key] = str(value)
    with log.open("x") as stream:
        result = subprocess.run(["scripts/verify-xcode.sh", "test",
            "-only-testing:AI SpotlightTests/FileModeReliabilityEvaluationTests"],
            cwd=repository, env=environment, stdout=stream, stderr=subprocess.STDOUT)
    if not output.exists():
        print("No evaluation records were produced. Check the log and test-runner environment.")
        raise SystemExit(result.returncode or 1)
    summarize([output])
    rows = [json.loads(line) for line in output.read_text().splitlines()]
    started = [row["id"] for row in rows if row.get("event") == "attempt_started"]
    finished = [row for row in rows if row.get("event") == "attempt_finished"]
    complete = bool(started) and len(started) == len(set(started)) == len(finished) and set(started) == {row["id"] for row in finished}
    if not complete or any(not completed_success(row) for row in finished):
        print("The evaluation contains failed, missing or unfinished attempts. All records were retained.")
        raise SystemExit(result.returncode or 1)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
