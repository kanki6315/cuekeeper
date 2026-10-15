#!/usr/bin/env python3
"""Read-only CloudKit schema export and release verification. Standard library only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
MODEL = Path("Cuekeeper/Storage/Cuekeeper.xcdatamodeld")
SNAPSHOT = Path("cloudkit/schema.ckdb")
MANIFEST = Path("cloudkit/schema.json")


class SchemaError(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def model_files(root):
    paths = sorted(p for p in (root / MODEL).rglob("*")
                   if p.is_file() and (p.name == "contents" or p.name == ".xccurrentversion"))
    if not paths:
        raise SchemaError("Core Data model files are missing.")
    calendar = root / "Cuekeeper/CalendarPublisher.swift"
    if calendar.is_file():
        paths.append(calendar)
    backup = root / "Cuekeeper/CloudBackupStore.swift"
    if backup.is_file():
        paths.append(backup)
    return {str(p.relative_to(root)): digest(p.read_bytes()) for p in paths}


def identity(root):
    project = (root / "project.yml").read_text()
    teams = re.findall(r"^\s*DEVELOPMENT_TEAM:\s*['\"]?([A-Z0-9]+)", project, re.M)
    entitlements = plistlib.loads((root / "Cuekeeper/Cuekeeper.entitlements").read_bytes())
    containers = entitlements.get("com.apple.developer.icloud-container-identifiers", [])
    if len(set(teams)) != 1 or len(containers) != 1:
        raise SchemaError("Expected one development team and one CloudKit container in the project.")
    return {"team": teams[0], "container": containers[0]}


# Preserve quoted identifiers; strip comments without changing quoted content.
TOKEN = re.compile(r'\s+|//[^\n]*|/\*[\s\S]*?\*/|"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z_0-9.]*|[0-9]+|[^\s]')


def schema_tokens(source):
    return [m.group() for m in TOKEN.finditer(source)
            if not m.group().isspace() and not m.group().startswith(("//", "/*"))]


def split_tokens(tokens, delimiter):
    parts, current, depth = [], [], 0
    for token in tokens:
        if token == "(":
            depth += 1
        elif token == ")":
            depth -= 1
            if depth < 0:
                raise SchemaError("Unbalanced schema declaration.")
        if token == delimiter and depth == 0:
            if current:
                parts.append(tuple(current))
            current = []
        else:
            current.append(token)
    if depth:
        raise SchemaError("Unbalanced schema declaration.")
    if current:
        parts.append(tuple(current))
    return parts


def unquote(token):
    return json.loads(token) if token.startswith('"') else token


def parse_schema(source):
    tokens = schema_tokens(source)
    if tokens[:2] != ["DEFINE", "SCHEMA"]:
        raise SchemaError("Expected a cktool DEFINE SCHEMA export.")
    records, declarations = {}, []
    for statement in split_tokens(tokens[2:], ";"):
        if statement[:2] == ("RECORD", "TYPE"):
            if len(statement) < 5 or statement[3] != "(" or statement[-1] != ")":
                raise SchemaError("Unrecognized record declaration.")
            name = unquote(statement[2])
            if name in records:
                raise SchemaError(f"Duplicate record type {name}.")
            fields = tuple(sorted(split_tokens(statement[4:-1], ",")))
            records[name] = fields
            declarations.append(("RECORD", name, fields))
        else:
            # Retain roles and any other declarations in the comparison.
            declarations.append(("OTHER", tuple(statement)))
    return records, tuple(sorted(declarations))


def required_fields(root):
    folder = root / MODEL
    version = folder / ".xccurrentversion"
    if version.exists():
        name = plistlib.loads(version.read_bytes())["_XCCurrentVersionName"]
        contents = folder / name / "contents"
    else:
        candidates = list(folder.glob("*.xcdatamodel/contents"))
        if len(candidates) != 1:
            raise SchemaError("Select the current Core Data model version before exporting.")
        contents = candidates[0]
    model = ET.parse(contents).getroot()
    return {"CD_" + entity.attrib["name"]:
            {"CD_" + attr.attrib["name"] for attr in entity.findall("attribute")
             if attr.get("transient") != "YES"}
            for entity in model.findall("entity") if entity.get("abstract") != "YES"}


def require_model_records(root, source):
    records, _ = parse_schema(source)
    required = required_fields(root)
    if (root / "Cuekeeper/CalendarPublisher.swift").is_file():
        required["CuekeeperCalendarPublisher"] = {"ownerID", "ownerName"}
    if (root / "Cuekeeper/CloudBackupStore.swift").is_file():
        required["CuekeeperBackup"] = {"savedAt", "byteCount", "eventCount", "payload"}
        required["CuekeeperBackupIndex"] = {"backupNames"}
    for name, expected in required.items():
        actual = {unquote(item[0]) for item in records.get(name, ()) if item and item[0] != "GRANT"}
        missing = expected - actual
        if name not in records or missing:
            raise SchemaError(f"Development schema is not initialized for {name}; missing fields: "
                              f"{', '.join(sorted(missing)) or '(record type)'}. "
                              "Run './cloudkit.sh init' on an iCloud-signed-in Mac first.")


def run_cktool(arguments):
    try:
        result = subprocess.run(["xcrun", "cktool", *arguments], capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SchemaError(f"Could not run cktool: {error}") from error
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        token = os.environ.get("CLOUDKIT_MANAGEMENT_TOKEN")
        if token:
            detail = detail.replace(token, "[redacted]")
        raise SchemaError("cktool failed. Save a CloudKit management token with "
                          "`xcrun cktool save-token --type management` and verify container access.\n" + detail[:2500])


def remote_export(account, environment, output):
    run_cktool(["export-schema", "--team-id", account["team"], "--container-id", account["container"],
                "--environment", environment, "--output-file", str(output)])
    if not output.is_file() or not output.stat().st_size:
        raise SchemaError("cktool returned no schema; existing snapshot was preserved.")
    return output.read_text()


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def export_development(root):
    account = identity(root)
    before = model_files(root)
    with tempfile.TemporaryDirectory(prefix="cuekeeper-cloudkit-") as directory:
        source = remote_export(account, "development", Path(directory) / "development.ckdb")
        require_model_records(root, source)
        if before != model_files(root):
            raise SchemaError("Model changed during export; retry after saving your edits.")
        manifest = {"format": 1, **account, "environment": "development",
                    "schema_sha256": digest(source.encode()), "model_files": before}
        # A partial write cannot pass the manifest/hash check.
        atomic_write(root / SNAPSHOT, source)
        atomic_write(root / MANIFEST, json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"Exported {SNAPSHOT} and {MANIFEST}. Review and commit both files.")


def check_local(root, team=None):
    if not (root / SNAPSHOT).is_file() or not (root / MANIFEST).is_file():
        raise SchemaError("No reviewed schema snapshot. Initialize the Development schema, then run "
                          "`./cloudkit.sh export` and commit cloudkit/schema.ckdb and cloudkit/schema.json.")
    account = identity(root)
    if team is not None and team != account["team"]:
        raise SchemaError("Release team differs from the CloudKit project's team.")
    manifest = json.loads((root / MANIFEST).read_text())
    if any(manifest.get(key) != value for key, value in {"format": 1, **account, "environment": "development"}.items()):
        raise SchemaError("Schema manifest belongs to a different team, container, or format. Re-export it.")
    if manifest.get("model_files") != model_files(root):
        raise SchemaError("Core Data model changed after schema export. Run the initialization scheme again, "
                          "then export, review, and commit the updated schema.")
    source = (root / SNAPSHOT).read_text()
    if manifest.get("schema_sha256") != digest(source.encode()):
        raise SchemaError("Schema snapshot does not match its manifest. Re-export rather than editing it by hand.")
    require_model_records(root, source)
    return account, source


def check_production(root, team=None):
    account, expected = check_local(root, team)
    with tempfile.TemporaryDirectory(prefix="cuekeeper-cloudkit-") as directory:
        current = remote_export(account, "production", Path(directory) / "production.ckdb")
        if parse_schema(current)[1] != parse_schema(expected)[1]:
            raise SchemaError("Production schema differs from the reviewed snapshot. Review schema changes in "
                              "CloudKit Console and deploy the intended Development schema to Production, "
                              "then rerun `./cloudkit.sh check`. Nothing was deployed by this command.")
    print("CloudKit release check passed: current model snapshot matches the live Production schema.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("export", help="Export Development schema and model fingerprint for review/commit")
    check = subcommands.add_parser("check", help="Require a fresh snapshot matching the live Production schema")
    check.add_argument("--local-only", action="store_true", help="Check snapshot/model without contacting Apple; not a release check")
    check.add_argument("--team", help="Require this release team to match the project")
    args = parser.parse_args()
    try:
        if args.command == "export":
            export_development(ROOT)
        elif args.local_only:
            check_local(ROOT, args.team)
            print("Local snapshot matches the model. Production has NOT been checked.")
        else:
            check_production(ROOT, args.team)
    except (SchemaError, OSError, ValueError, KeyError, ET.ParseError) as error:
        print(f"CloudKit: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
