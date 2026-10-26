"""Offline source validation. A green result does not prove Civ VI behavior."""
from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import sqlite3
import subprocess
import sys
import xml.etree.ElementTree as ET

from sync_dev import sync

ROOT = Path(__file__).resolve().parents[1]
GS_ID = "4873eb62-8ccc-4574-b784-dda455e74e68"
# Strings/comments must not introduce fake calls or tunable literals.
LUA_TOKEN = re.compile(r"--\[(=*)\[.*?\]\1\]|--[^\n]*|\[(=*)\[.*?\]\2\]|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"", re.S)
NUMBER = re.compile(r"(?<![\w.])(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)(?![\w.])")
CALL = re.compile(r"([:.])([A-Za-z_]\w*)\s*\(")
ENGINE_ROOTS = {"Game", "GameInfo", "GameConfiguration", "PlayerConfigurations", "Players", "PlayerManager", "UI", "ContextPtr", "Controls", "Events", "GameEvents", "LuaEvents", "Map", "Cities", "UnitManager", "NotificationManager", "DealManager", "TerrainBuilder", "Automation", "Network", "ExposedMembers"}
PURE_ROOTS = {"math", "string", "table", "WBL_Math", "WBL_MATH", "WBL_CONFIG"}


def masked_lua(source: str) -> str:
    return LUA_TOKEN.sub(lambda match: "".join("\n" if char == "\n" else " " for char in match.group()), source)


def safe_relative(value: str) -> Path:
    if not value or "\\" in value or ":" in value:
        raise ValueError(f"unsafe manifest path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in (".", "..") for part in value.split("/")):
        raise ValueError(f"unsafe manifest path: {value!r}")
    if any(part.rstrip(" .") != part or not part for part in value.split("/")):
        raise ValueError(f"ambiguous manifest path: {value!r}")
    return Path(*path.parts)


def manifest_files(mod_dir: Path) -> list[Path]:
    manifests = list(mod_dir.glob("*.modinfo"))
    if len(manifests) != 1:
        raise ValueError(f"{mod_dir.name}: expected exactly one modinfo")
    manifest = manifests[0]
    document = ET.parse(manifest).getroot()
    declared = [safe_relative(item.text or "") for item in document.findall("./Files/File")]
    folded = [str(path).casefold() for path in declared]
    if len(folded) != len(set(folded)):
        raise ValueError(f"{manifest.name}: duplicate Files entry")
    result = [Path(manifest.name), *declared]
    for relative in result:
        source = mod_dir / relative
        if not source.is_file() or not source.resolve().is_relative_to(mod_dir.resolve()):
            raise ValueError(f"{manifest.name}: missing or escaping file {relative}")
    listed = set(folded)
    for item in document.findall("./InGameActions/*/File") + document.findall("./FrontEndActions/*/File"):
        relative = safe_relative(item.text or "")
        if str(relative).casefold() not in listed:
            raise ValueError(f"{manifest.name}: action file missing from Files: {relative}")
    for item in document.findall("./InGameActions/AddUserInterfaces/File"):
        relative = safe_relative(item.text or "")
        if relative.suffix != ".xml" or str(relative.with_suffix(".lua")).casefold() not in listed:
            raise ValueError(f"{manifest.name}: UI XML needs a listed Lua sibling: {relative}")
    return sorted(result, key=lambda path: path.as_posix().casefold())


def check_manifest(mod_dir: Path) -> list[str]:
    errors = []
    try:
        files = manifest_files(mod_dir)
        document = ET.parse(next(mod_dir.glob("*.modinfo"))).getroot()
        if GS_ID not in {item.get("id") for item in document.findall("./Dependencies/Mod")}:
            errors.append(f"{mod_dir.name}: missing Gathering Storm dependency")
        if not document.findall("./ActionCriteria/Criteria/GameCoreInUse"):
            errors.append(f"{mod_dir.name}: missing gamecore criterion")
        actual = {path.relative_to(mod_dir).as_posix().casefold() for path in mod_dir.rglob("*") if path.is_file()}
        listed = {path.as_posix().casefold() for path in files}
        if actual != listed:
            errors.append(f"{mod_dir.name}: unlisted files: {sorted(actual - listed)}")
        text_keys = {item.get("id") for item in document.findall("./LocalizedText/Text")}
        for relative in files:
            if relative.suffix == ".xml":
                parsed = ET.parse(mod_dir / relative).getroot()
                text_keys.update(item.get("Tag") for item in parsed.iter("Row") if item.get("Tag"))
        for relative in files:
            if relative.suffix not in (".xml", ".modinfo", ".lua"):
                continue
            text = (mod_dir / relative).read_text(encoding="utf-8-sig")
            for key in set(re.findall(r"\bLOC_WBL_[A-Z_0-9]+", text)):
                if key not in text_keys:
                    errors.append(f"{relative}: undefined localization key {key}")
    except (ValueError, ET.ParseError, OSError) as error:
        errors.append(str(error))
    return errors


def engine_calls(source: str) -> set[str]:
    code = masked_lua(source)

    def start_of_expression(end: int) -> int:
        index = end - 1
        while index >= 0 and code[index].isspace():
            index -= 1
        if index < 0:
            return end
        if code[index] in ")]":
            closing, opening = code[index], "(" if code[index] == ")" else "["
            depth = 1
            index -= 1
            while index >= 0 and depth:
                depth += (code[index] == closing) - (code[index] == opening)
                index -= 1
            return start_of_expression(index + 1) if depth == 0 else end
        if not (code[index].isalnum() or code[index] == "_"):
            return end
        while index >= 0 and (code[index].isalnum() or code[index] == "_"):
            index -= 1
        start = index + 1
        while index >= 0 and code[index].isspace():
            index -= 1
        if index >= 0 and code[index] in ".:" and not (code[index] == "." and index > 0 and code[index - 1] == "."):
            return start_of_expression(index)
        return start

    def normalize(expression: str) -> str:
        result, index = [], 0
        while index < len(expression):
            char = expression[index]
            if char in "([":
                closing = ")" if char == "(" else "]"
                depth = 1
                index += 1
                while index < len(expression) and depth:
                    depth += (expression[index] == char) - (expression[index] == closing)
                    index += 1
                result.append(char + closing)
                continue
            if not char.isspace():
                result.append(char)
            index += 1
        return "".join(result)

    calls = set()
    for match in CALL.finditer(code):
        start = start_of_expression(match.start())
        if start >= match.start():
            continue
        expression = normalize(code[start:match.end() - 1])
        root = re.split(r"[.:[ ]", expression, maxsplit=1)[0]
        if not root:
            calls.add("<computed>" + expression)
            continue
        if expression == "tostring():gsub":
            continue  # Standard Lua string method; no engine binding.
        # Colon calls on named engine objects must be reviewed individually.
        if ":" in expression or root in ENGINE_ROOTS:
            calls.add(expression)
        elif root not in PURE_ROOTS and root[0].isupper():
            calls.add(expression)
    return calls


def audit_lua(path: str, source: str, policy: dict) -> list[str]:
    errors = []
    rules = policy.get("apis", {}).get(path, {})
    modules = policy.get("module_namespaces", policy.get("pure_modules", {})).get(path, {})
    for expression in sorted(engine_calls(source)):
        namespace = expression.split(".", 1)[0]
        if ":" not in expression and namespace in modules:
            if namespace.startswith("WBL_") or re.search(r"\blocal\s+" + re.escape(namespace) + r"\s*=\s*(?:\{|WBL_[A-Z_]+\b)", masked_lua(source)):
                continue  # Local Lua module; its implementation is audited separately.
        evidence = rules.get(expression)
        if not evidence or not isinstance(evidence, str) or not re.search(r":\d+", evidence):
            errors.append(f"{path}: unverified API {expression}")
    if path.endswith("WBL_Config.lua"):
        return errors
    allowed = policy.get("numbers", {}).get(path, {})
    for literal in sorted(set(NUMBER.findall(masked_lua(source)))):
        if literal not in allowed or not allowed[literal]:
            errors.append(f"{path}: numeric literal {literal} needs a constant/tuning rationale")
    return errors


def audit_gameplay(path: str, source: str) -> list[str]:
    """Apply sync rules to actual gameplay entrypoints, regardless of folder."""
    code = masked_lua(source)
    errors = []
    prohibited = {
        r"\bGame\s*\.\s*GetLocalPlayer\s*\(": "gameplay may not use the local player",
        r"\bmath\s*\.\s*random(?:seed)?\s*\(": "gameplay may not use math.random",
        r"\bpairs\s*\(": "gameplay iteration must be ordered (ipairs or sorted indices)",
        r"(?<![\w.])Events\.[A-Za-z_]\w*\.Add\s*\(": "gameplay must subscribe through synced GameEvents, not asynchronous Events",
    }
    for pattern, message in prohibited.items():
        if re.search(pattern, code):
            errors.append(f"{path}: {message}")
    return errors


def audit_deal_actions(path: str, source: str) -> list[str]:
    errors = []
    for argument in re.findall(r"\bDealManager\.SendWorkingDeal\s*\(\s*([^,)]+)", masked_lua(source)):
        if re.sub(r"\s+", "", argument) != "DealProposalAction.INSPECT":
            errors.append(f"{path}: only the nonbinding INSPECT action is permitted")
    return errors


def gameplay_modules(mod_dir: Path, documents: list) -> set[Path]:
    """Trace local includes from gameplay entries; UI modules keep their own context."""
    by_name = {path.stem: path.resolve() for path in mod_dir.rglob("*.lua")}
    pending = [(mod_dir / safe_relative(item.text or "")).resolve()
        for document in documents for item in document.findall("./InGameActions/AddGameplayScripts/File")]
    found = set()
    while pending:
        path = pending.pop()
        if path in found or not path.is_file():
            continue
        found.add(path)
        source = path.read_text(encoding="utf-8-sig")
        for name in re.findall(r'\binclude\s*\(\s*[\"\']([^\"\']+)[\"\']', source):
            module = by_name.get(Path(name).stem)
            if module is not None and module not in found:
                pending.append(module)
    return found


def validate_sql(sql_path: Path, database: Path) -> list[str]:
    """Run generated rows against an in-memory clone, never the live database."""
    if not database.is_file():
        return ["game schema source missing; cannot verify experimental SQL: " + str(database)]
    try:
        with sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True) as source:
            with sqlite3.connect(":memory:") as scratch:
                source.backup(scratch)
                # Civ VI supplies Make_Hash to its SQLite connection. Ordinary
                # sqlite3 cannot verify those hashes; remove only hash-maintenance
                # triggers in this disposable clone, never fabricate engine hashes.
                for trigger in ("OnTypeInsert", "OnKindInsert"):
                    row = scratch.execute("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", (trigger,)).fetchone()
                    if row and "Make_Hash" in row[0]:
                        scratch.execute(f'DROP TRIGGER "{trigger}"')
                scratch.execute("PRAGMA foreign_keys=ON")
                baseline = set(scratch.execute("PRAGMA foreign_key_check"))
                scratch.executescript(sql_path.read_text(encoding="utf-8-sig"))
                violations = set(scratch.execute("PRAGMA foreign_key_check")) - baseline
                if violations:
                    return [f"generated SQL introduces invalid references: {sorted(violations)}"]
                # Some Civ VI schema references are soft, not foreign keys.
                checks = (
                    ("modifier types", "SELECT m.ModifierType FROM Modifiers m LEFT JOIN DynamicModifiers d ON m.ModifierType=d.ModifierType WHERE m.ModifierId LIKE 'WBL_%' AND d.ModifierType IS NULL"),
                    ("requirement types", "SELECT r.RequirementType FROM Requirements r LEFT JOIN Types t ON r.RequirementType=t.Type AND t.Kind='KIND_REQUIREMENT' WHERE r.RequirementId LIKE 'WBL_%' AND t.Type IS NULL"),
                    ("effect types", "SELECT d.EffectType FROM DynamicModifiers d LEFT JOIN Types t ON d.EffectType=t.Type AND t.Kind='KIND_EFFECT' WHERE d.ModifierType LIKE 'WBL_%' AND t.Type IS NULL"),
                    ("collection types", "SELECT d.CollectionType FROM DynamicModifiers d LEFT JOIN Types t ON d.CollectionType=t.Type AND t.Kind='KIND_COLLECTION' WHERE d.ModifierType LIKE 'WBL_%' AND t.Type IS NULL"),
                )
                errors = []
                for label, query in checks:
                    rows = scratch.execute(query).fetchall()
                    if rows:
                        errors.append(f"generated SQL uses unknown {label}: {rows}")
                return errors
    except (sqlite3.Error, OSError) as error:
        return [f"generated SQL validation failed: {error}"]


def check_repo(root: Path = ROOT) -> list[str]:
    errors = []
    try:
        from lupa.lua51 import LuaRuntime
        lua = LuaRuntime(unpack_returned_tuples=True)
        parse = lua.eval("function(source, name) local f, err = loadstring(source, name); return f ~= nil, err end")
        if lua.eval("_VERSION") != "Lua 5.1":
            errors.append("wrong Lua runtime; explicit Lua 5.1 required")
    except ImportError:
        return ["lupa.lua51 unavailable; install lupa for the selected Python"]
    try:
        policy = json.loads((root / "tools" / "source_policy.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return [f"source policy unavailable: {error}"]
    for folder in ("WBL", "WBL_Dev"):
        mod_dir = root / folder
        manifests = list(mod_dir.glob("*.modinfo"))
        entries = set()
        if manifests:
            errors.extend(check_manifest(mod_dir))
            documents = []
            for manifest in manifests:
                try:
                    document = ET.parse(manifest).getroot()
                    documents.append(document)
                except (ValueError, ET.ParseError, OSError) as error:
                    errors.append(str(error))
            entries = gameplay_modules(mod_dir, documents)
        for path in sorted(mod_dir.rglob("*.lua")):
            relative = path.relative_to(root).as_posix()
            source = path.read_text(encoding="utf-8-sig")
            valid, error = parse(source, relative)
            if not valid:
                errors.append(f"{relative}: Lua 5.1 syntax: {error}")
            errors.extend(audit_lua(relative, source, policy))
            if path.name == "WBL_Dev_Deals.lua":
                errors.extend(audit_deal_actions(relative, source))
            if path.resolve() in entries:
                errors.extend(audit_gameplay(relative, source))
    errors.extend(sync(root, check=True))
    generator = root / "tools" / "generate_spike_sql.py"
    if generator.exists():
        result = subprocess.run([sys.executable, str(generator), "--check"], cwd=root, capture_output=True, text=True)
        if result.returncode:
            errors.append("generated spike SQL drift: " + (result.stdout + result.stderr).strip())
    sql_path = root / "WBL_Dev" / "Data" / "WBL_SpikeModifiers.sql"
    if sql_path.exists():
        from os import environ
        candidates = [Path(environ.get("LOCALAPPDATA", "")), Path(environ.get("USERPROFILE", "")) / "AppData" / "Local"]
        databases = [candidate / "Firaxis Games" / "Sid Meier's Civilization VI" / "Cache" / "DebugGameplay.sqlite" for candidate in candidates]
        database = next((candidate for candidate in databases if candidate.is_file()), databases[0])
        errors.extend(validate_sql(sql_path, database))
    config_path = root / "WBL" / "Scripts" / "WBL_Config.lua"
    dev_manifest = root / "WBL_Dev" / "WBL_Dev.modinfo"
    if config_path.exists() and dev_manifest.exists():
        lua.execute(config_path.read_text(encoding="utf-8-sig"))
        dev_version = lua.globals().WBL_CONFIG["devVersion"]
        if not dev_version or f"Version {dev_version}." not in dev_manifest.read_text(encoding="utf-8-sig"):
            errors.append("dev modinfo version does not match authoritative WBL_CONFIG.devVersion")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list-manifest", type=Path, help="print safe exact file list (used by installer)")
    args = parser.parse_args()
    if args.list_manifest:
        try:
            print("\n".join(path.as_posix() for path in manifest_files(args.list_manifest)))
        except (ValueError, OSError, ET.ParseError) as error:
            print(error, file=sys.stderr)
            return 1
        return 0
    errors = check_repo()
    for error in errors:
        print("FAIL:", error)
    if not errors:
        print("PASS: offline Lua 5.1, manifest, localization, API/numeric policy and generated parity checks")
        print("PENDING: actual in-game engine behavior and multiplayer verification")
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
