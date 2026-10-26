"""Generate byte-identical dev imports from the one authoritative rules source."""
from __future__ import annotations

import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IMPORTS = ("WBL_Config.lua", "WBL_Math.lua")


def sync(root: Path = ROOT, check: bool = False) -> list[str]:
    errors = []
    for name in IMPORTS:
        source = root / "WBL" / "Scripts" / name
        target = root / "WBL_Dev" / "Scripts" / name
        if not source.is_file():
            errors.append(f"missing authoritative source: {source.relative_to(root)}")
        elif check:
            if not target.is_file() or target.read_bytes() != source.read_bytes():
                errors.append(f"generated import differs: {target.relative_to(root)}; run tools/sync_dev.py")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    errors = sync(check=args.check)
    for error in errors:
        print("FAIL:", error)
    if not errors:
        print("PASS: generated dev imports match the authoritative source" if args.check else "Generated dev imports from authoritative source")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
