#!/usr/bin/env python3
"""Bounded, redacted Relay evidence capture and artifact secret scanning."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


TOKEN_PATTERNS = (
    re.compile(r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]*"),
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]*\b"),
    re.compile(r"\bsk-[A-Za-z0-9_-]*\b"),
    re.compile(
        r"(?i)(?:api[_-]?key|token|secret|password)\s*[=:]\s*[^\s]*"
    ),
)
MAX_SCAN_FILE_BYTES = 2 * 1024 * 1024
DIAGNOSTIC_OVERLAP_BYTES = 64 * 1024
SENSITIVE_ENVIRONMENT_NAME = re.compile(
    r"(?i)(?:token|secret|password|credential|api[_-]?key|access[_-]?key|private[_-]?key)"
)
XCTEST_CASE_STARTED = re.compile(rb"^Test Case '.+' started\.$")
XCTEST_EXECUTED_SUMMARY = re.compile(
    rb"^Executed ([0-9]+) tests?, with ([0-9]+) failures?"
)


def explicit_literals() -> list[str]:
    encoded = os.environ.get("RELAY_EVIDENCE_REDACT_LITERALS_JSON", "[]")
    try:
        values = json.loads(encoded)
    except json.JSONDecodeError as error:
        raise ValueError("invalid RELAY_EVIDENCE_REDACT_LITERALS_JSON") from error
    if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
        raise ValueError("redaction literals must be a JSON string array")
    environment_values = (
        value
        for name, value in os.environ.items()
        if SENSITIVE_ENVIRONMENT_NAME.search(name)
        and len(value) >= 8
        and name != "RELAY_EVIDENCE_REDACT_LITERALS_JSON"
    )
    return sorted(
        set(item for item in [*values, *environment_values] if item),
        key=len,
        reverse=True,
    )


def redact(text: str, literals: list[str]) -> tuple[str, int]:
    count = 0
    for literal in literals:
        occurrences = text.count(literal)
        if occurrences:
            text = text.replace(literal, "<redacted>")
            count += occurrences
        # If retention cut the literal at the final byte, do not retain its
        # recognizable prefix. Four bytes avoids redacting ordinary suffixes.
        for length in range(len(literal) - 1, min(3, len(literal) - 1), -1):
            if text.endswith(literal[:length]):
                text = text[:-length] + "<redacted>"
                count += 1
                break
    for pattern in TOKEN_PATTERNS:
        text, replacements = pattern.subn("<redacted>", text)
        count += replacements
    return text, count


def bounded_utf8(text: str, limit: int) -> bytes:
    encoded = text.encode("utf-8")
    if len(encoded) <= limit:
        return encoded
    return encoded[:limit].decode("utf-8", errors="ignore").encode("utf-8")


def write_private(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def capture(args: argparse.Namespace) -> int:
    if args.limit < 0 or args.limit > 16 * 1024 * 1024:
        raise ValueError("capture limit is outside the supported range")
    if len(args.diagnostic_regex) > 4096:
        raise ValueError("diagnostic regex is too large")
    diagnostic = re.compile(args.diagnostic_regex, re.IGNORECASE)
    literals = explicit_literals()
    digest = hashlib.sha256()
    retained = bytearray()
    total = 0
    detected = False
    diagnostic_tail = b""
    line_buffer = bytearray()
    xctest_case_started_count = 0
    xctest_executed_summary_max = 0

    def inspect_line(line: bytes) -> None:
        nonlocal xctest_case_started_count, xctest_executed_summary_max
        normalized = line.strip()
        if XCTEST_CASE_STARTED.match(normalized):
            xctest_case_started_count += 1
        summary = XCTEST_EXECUTED_SUMMARY.match(normalized)
        if summary:
            xctest_executed_summary_max = max(
                xctest_executed_summary_max,
                int(summary.group(1)),
            )

    while True:
        chunk = sys.stdin.buffer.read(64 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        total += len(chunk)
        if len(retained) < args.limit:
            retained.extend(chunk[: args.limit - len(retained)])
        diagnostic_window = diagnostic_tail + chunk
        if diagnostic.search(diagnostic_window.decode("utf-8", errors="replace")):
            detected = True
        diagnostic_tail = diagnostic_window[-DIAGNOSTIC_OVERLAP_BYTES:]
        line_buffer.extend(chunk)
        while True:
            newline = line_buffer.find(b"\n")
            if newline < 0:
                break
            inspect_line(bytes(line_buffer[:newline]))
            del line_buffer[: newline + 1]

    if line_buffer:
        inspect_line(bytes(line_buffer))

    redacted, redaction_count = redact(
        retained.decode("utf-8", errors="replace"), literals
    )
    retained_output = bounded_utf8(redacted, args.limit)
    write_private(Path(args.output), retained_output)
    metadata = "\n".join(
        (
            f"full_stream_sha256={digest.hexdigest()}",
            f"total_byte_count={total}",
            f"retained_raw_byte_count={len(retained)}",
            f"retained_redacted_byte_count={len(retained_output)}",
            f"was_truncated={int(total > len(retained))}",
            f"redaction_count={redaction_count}",
            f"diagnostic_detected={int(detected)}",
            f"xctest_case_started_count={xctest_case_started_count}",
            f"xctest_executed_summary_max={xctest_executed_summary_max}",
            "",
        )
    ).encode("utf-8")
    write_private(Path(args.metadata), metadata)
    return 0


def scan_artifacts(paths: list[str]) -> int:
    literals = explicit_literals()
    for encoded_path in paths:
        path = Path(encoded_path)
        facts = path.lstat()
        if not stat.S_ISREG(facts.st_mode) or facts.st_size > MAX_SCAN_FILE_BYTES:
            raise ValueError(f"unsafe evidence artifact: {path.name}")
        text = path.read_text(encoding="utf-8", errors="replace")
        for literal in literals:
            if literal in text:
                print(f"secret literal remains in {path.name}", file=sys.stderr)
                return 1
        if any(pattern.search(text) for pattern in TOKEN_PATTERNS):
            print(f"secret-shaped value remains in {path.name}", file=sys.stderr)
            return 1
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subparsers = result.add_subparsers(dest="operation", required=True)
    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--output", required=True)
    capture_parser.add_argument("--metadata", required=True)
    capture_parser.add_argument("--limit", type=int, required=True)
    capture_parser.add_argument("--diagnostic-regex", required=True)
    scan_parser = subparsers.add_parser("scan-artifacts")
    scan_parser.add_argument("paths", nargs="+")
    return result


def main() -> int:
    args = parser().parse_args()
    if args.operation == "capture":
        return capture(args)
    return scan_artifacts(args.paths)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, re.error) as error:
        print(f"Relay evidence helper failed: {error}", file=sys.stderr)
        raise SystemExit(2) from error
