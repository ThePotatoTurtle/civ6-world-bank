"""Single offline entry point. A missing Lua runtime is a failure, never a live-spike PASS."""
from pathlib import Path
import sys
import unittest


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    suite = unittest.defaultTestLoader.discover(str(root / "tests" / "offline"), pattern="test_*.py")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
