"""Package exactly one modinfo manifest, verifying every copied byte."""
from __future__ import annotations

import argparse
from pathlib import Path
import tempfile
import zipfile

from check_all import manifest_files


def package(mod_dir: Path, output: Path) -> Path:
    mod_dir = mod_dir.resolve()
    files = manifest_files(mod_dir)
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    # A fresh stage avoids stale release files; TemporaryDirectory owns its cleanup.
    with tempfile.TemporaryDirectory(prefix="wbl-package-") as temporary:
        stage = Path(temporary) / mod_dir.name
        for relative in files:
            source, target = mod_dir / relative, stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
            if target.read_bytes() != source.read_bytes():
                raise ValueError(f"copied bytes differ: {relative}")
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for relative in files:
                info = zipfile.ZipInfo(f"{mod_dir.name}/{relative.as_posix()}", date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, (stage / relative).read_bytes())
        with zipfile.ZipFile(output) as archive:
            expected = {f"{mod_dir.name}/{relative.as_posix()}" for relative in files}
            if set(archive.namelist()) != expected:
                raise ValueError("archive differs from manifest")
            for relative in files:
                if archive.read(f"{mod_dir.name}/{relative.as_posix()}") != (mod_dir / relative).read_bytes():
                    raise ValueError(f"archive bytes differ: {relative}")
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mod", type=Path, default=Path(__file__).resolve().parents[1] / "WBL_Dev")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(package(args.mod, args.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
