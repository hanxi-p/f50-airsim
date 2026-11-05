"""Compare shared imported CRCs without claiming complete kernel ABI coverage."""
import argparse
import json
from pathlib import Path, PurePosixPath
import runpy
import tarfile
import tempfile


def modules(archive, read_module):
    with tempfile.TemporaryDirectory() as scratch, tarfile.open(archive) as source:
        for member in source:
            if member.isfile() and member.name.endswith(".ko"):
                path = Path(scratch) / PurePosixPath(member.name).name
                path.write_bytes(source.extractfile(member).read())
                yield path.name, read_module(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference")
    parser.add_argument("candidate")
    parser.add_argument("--reader", default="upstream/airsim-mu300/scripts/openwrt-audio-abi.py")
    args = parser.parse_args()
    reader = runpy.run_path(args.reader)["module"]
    references = list(modules(args.reference, reader))
    candidates = list(modules(args.candidate, reader))
    reference_magic = {magic for _, (magic, _) in references}
    versions = {}
    for _, (_, imports) in references:
        for symbol, crc in imports.items():
            versions.setdefault(symbol, set()).add(crc)

    shared = set()
    checked = total = 0
    errors = []
    for name, (magic, imports) in candidates:
        if magic not in reference_magic:
            errors.append(f"{name}: vermagic differs")
        total += len(imports)
        for symbol, crc in imports.items():
            if symbol in versions:
                checked += 1
                shared.add(symbol)
                if versions[symbol] != {crc}:
                    errors.append(f"{name}: {symbol} CRC differs")
    if len(candidates) != 24 or "module_layout" not in shared:
        errors.append("Missing expected module or CRC coverage")
    print(json.dumps(dict(references=len(references), candidates=len(candidates),
                          import_records=total, checked_records=checked,
                          shared_symbols=len(shared), errors=errors), indent=2))
    raise SystemExit(bool(errors))


if __name__ == "__main__":
    main()
