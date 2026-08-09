#!/usr/bin/env python3
"""Run localization checker tests without leaving Python bytecode in the tree."""

from __future__ import annotations

import pathlib
import sys
import unittest


sys.dont_write_bytecode = True


def main() -> int:
    tests = pathlib.Path(__file__).resolve().parent / "tests"
    suite = unittest.defaultTestLoader.discover(
        str(tests), pattern="test_localization_completeness.py"
    )
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
