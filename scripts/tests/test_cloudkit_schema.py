import importlib.util
import json
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("cloudkit_schema", ROOT / "scripts/cloudkit_schema.py")
ck = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ck)
REVIEWED_SCHEMA = (ROOT / "cloudkit/schema.ckdb").read_text()
# Synthetic successful export for the V15 model. The reviewed remote snapshot
# intentionally remains separate: updating this mock is not a schema deployment.
SCHEMA = REVIEWED_SCHEMA
if "CD_invoicingJSON" not in SCHEMA:
    SCHEMA = SCHEMA.replace("RECORD TYPE CD_Client (", "RECORD TYPE CD_Client (\n    CD_invoicingJSON STRING,")


class SchemaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / ck.MODEL, self.root / ck.MODEL)
        shutil.copy(ROOT / "Cuekeeper/Cuekeeper.entitlements", self.root / "Cuekeeper")
        shutil.copy(ROOT / "project.yml", self.root)
        shutil.copy(ROOT / "Cuekeeper/CalendarPublisher.swift", self.root / "Cuekeeper")
        shutil.copy(ROOT / "Cuekeeper/CloudBackupStore.swift", self.root / "Cuekeeper")

    def export(self, source=SCHEMA):
        with patch.object(ck, "remote_export", return_value=source):
            ck.export_development(self.root)

    def test_v7_export_is_not_sufficient_for_v8_release(self):
        with self.assertRaisesRegex(ck.SchemaError, "CD_WorkEvent"):
            ck.require_model_records(self.root, re.sub(r"RECORD TYPE CD_WorkEvent\s*\(.*?\);", "", SCHEMA, flags=re.S))

    def test_missing_snapshot_blocks_release(self):
        with self.assertRaisesRegex(ck.SchemaError, "No reviewed schema"):
            ck.check_local(self.root)

    def test_export_without_client_invoicing_field_blocks_v15(self):
        source = re.sub(r"\s*CD_invoicingJSON\s+STRING[^,]*,", "", SCHEMA)
        with self.assertRaisesRegex(ck.SchemaError, "CD_invoicingJSON"):
            self.export(source)

    def test_only_users_type_is_not_a_valid_model_export(self):
        with self.assertRaisesRegex(ck.SchemaError, "not initialized"):
            self.export('DEFINE SCHEMA RECORD TYPE Users (roles LIST<INT64>);')
        self.assertFalse((self.root / ck.SNAPSHOT).exists())

    def test_export_records_identity_and_current_model(self):
        self.export()
        account, source = ck.check_local(self.root)
        self.assertEqual(account["container"], "iCloud.com.arjunakankipati.cuekeeper")
        self.assertEqual(source, SCHEMA)

    def test_model_change_blocks_even_if_schema_fields_still_exist(self):
        self.export()
        model = next((self.root / ck.MODEL).rglob("contents"))
        model.write_text(model.read_text().replace('attributeType="String"', 'attributeType="Binary"', 1))
        with self.assertRaisesRegex(ck.SchemaError, "model changed"):
            ck.check_local(self.root)

    def test_snapshot_edit_and_wrong_team_are_rejected(self):
        self.export()
        with self.assertRaisesRegex(ck.SchemaError, "Release team differs"):
            ck.check_local(self.root, "OTHERTEAM")
        (self.root / ck.SNAPSHOT).write_text(SCHEMA.replace("QUERYABLE", ""))
        with self.assertRaisesRegex(ck.SchemaError, "does not match its manifest"):
            ck.check_local(self.root)

    def test_wrong_container_manifest_is_rejected(self):
        self.export()
        manifest = self.root / ck.MANIFEST
        value = json.loads(manifest.read_text())
        value["container"] = "iCloud.other.app"
        manifest.write_text(json.dumps(value))
        with self.assertRaisesRegex(ck.SchemaError, "different team, container"):
            ck.check_local(self.root)

    def test_failed_export_preserves_reviewed_files(self):
        self.export()
        previous = [(self.root / p).read_bytes() for p in [ck.SNAPSHOT, ck.MANIFEST]]
        with patch.object(ck, "remote_export", side_effect=ck.SchemaError("No token")):
            with self.assertRaises(ck.SchemaError):
                ck.export_development(self.root)
        self.assertEqual(previous, [(self.root / p).read_bytes() for p in [ck.SNAPSHOT, ck.MANIFEST]])

    def test_order_whitespace_and_comments_do_not_create_drift(self):
        a = 'DEFINE SCHEMA RECORD TYPE A (x STRING, y INT64, GRANT READ TO "_world"); RECORD TYPE B (z STRING);'
        b = 'DEFINE SCHEMA // comment\nRECORD TYPE B(z STRING); RECORD TYPE A(GRANT READ TO "_world", y INT64,x STRING);'
        self.assertEqual(ck.parse_schema(a)[1], ck.parse_schema(b)[1])

    def test_index_type_and_permission_changes_block_production(self):
        self.export()
        for changed in [SCHEMA.replace("QUERYABLE", ""), SCHEMA.replace("TIMESTAMP", "STRING"),
                        SCHEMA.replace('"_creator"', '"_world"')]:
            with self.subTest(schema=changed), patch.object(ck, "remote_export", return_value=changed):
                with self.assertRaisesRegex(ck.SchemaError, "Production schema differs"):
                    ck.check_production(self.root)

    def test_matching_production_is_read_only_and_passes(self):
        self.export()
        with patch.object(ck, "remote_export", return_value=SCHEMA) as remote:
            ck.check_production(self.root)
            self.assertEqual(remote.call_args.args[1], "production")

    def test_auth_error_redacts_environment_token(self):
        with patch.dict("os.environ", {"CLOUDKIT_MANAGEMENT_TOKEN": "secret-token"}), patch.object(
            ck.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "bad secret-token")
        ):
            with self.assertRaises(ck.SchemaError) as context:
                ck.run_cktool(["export-schema"])
        self.assertNotIn("secret-token", str(context.exception))

    def test_duplicate_and_unbalanced_schema_rejected(self):
        for schema in ['DEFINE SCHEMA RECORD TYPE A(x STRING); RECORD TYPE A(x STRING);',
                       'DEFINE SCHEMA RECORD TYPE A(x STRING;']:
            with self.subTest(schema=schema), self.assertRaises(ck.SchemaError):
                ck.parse_schema(schema)


if __name__ == "__main__":
    unittest.main()
