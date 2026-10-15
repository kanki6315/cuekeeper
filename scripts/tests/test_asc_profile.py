import unittest
from unittest.mock import patch

import asc_profile


class ProfileEntitlementTests(unittest.TestCase):
    def test_cloudkit_service_permissions(self):
        base = {
            "com.apple.developer.team-identifier": "TEAM",
            "application-identifier": "TEAM.com.example.app",
            "com.apple.developer.icloud-container-identifiers": ["iCloud.example"],
            "com.apple.developer.icloud-container-environment": ["Production"],
            "aps-environment": "production",
            "com.apple.developer.weatherkit": True,
        }
        for services, expected in [("*", True), (["*"], True),
                                   (["CloudKit"], True), ("CloudKit", True),
                                   (["CloudDocuments"], False), ([], False)]:
            with self.subTest(services=services):
                entitlements = dict(base, **{"com.apple.developer.icloud-services": services})
                with patch.object(asc_profile, "profile_entitlements", return_value=entitlements):
                    self.assertEqual(asc_profile.supports_cloudkit(
                        {}, "TEAM", "com.example.app", "iCloud.example"), expected)
                    self.assertFalse(asc_profile.supports_cloudkit(
                        {}, "TEAM", "com.example.app", "iCloud.wrong"))

    def test_missing_weatherkit_is_rejected(self):
        entitlements = {
            "com.apple.developer.team-identifier": "TEAM",
            "application-identifier": "TEAM.com.example.app",
            "com.apple.developer.icloud-container-identifiers": ["iCloud.example"],
            "com.apple.developer.icloud-container-environment": "Production",
            "com.apple.developer.icloud-services": ["CloudKit"],
            "aps-environment": "production",
        }
        with patch.object(asc_profile, "profile_entitlements", return_value=entitlements):
            self.assertFalse(asc_profile.supports_cloudkit({}, "TEAM", "com.example.app", "iCloud.example"))


class TargetProfileTests(unittest.TestCase):
    def entitlements(self, bundle_id="com.example.app"):
        return {
            "com.apple.developer.team-identifier": "TEAM",
            "application-identifier": f"TEAM.{bundle_id}",
            "com.apple.security.application-groups": ["group.example"],
            "com.apple.developer.icloud-container-identifiers": ["iCloud.example"],
            "com.apple.developer.icloud-container-environment": "Production",
            "com.apple.developer.icloud-services": ["CloudKit"],
            "aps-environment": "production",
            "com.apple.developer.weatherkit": True,
        }

    def test_app_requires_group_and_existing_capabilities(self):
        entitlements = self.entitlements()
        for missing in [None, *entitlements]:
            with self.subTest(missing=missing):
                candidate = entitlements.copy()
                if missing:
                    candidate.pop(missing)
                with patch.object(asc_profile, "profile_entitlements", return_value=candidate):
                    self.assertEqual(asc_profile.supports_profile(
                        {}, "TEAM", "com.example.app", "group.example", "iCloud.example"),
                        missing is None)

    def test_widget_needs_only_identity_and_exact_group(self):
        for groups, expected in [(["group.example"], True), ([], False),
                                 (["group.other"], False), (["*"], False),
                                 ("group.example", False)]:
            with self.subTest(groups=groups):
                entitlements = {
                    "com.apple.developer.team-identifier": "TEAM",
                    "application-identifier": "TEAM.com.example.app.widgets",
                    "com.apple.security.application-groups": groups,
                }
                with patch.object(asc_profile, "profile_entitlements", return_value=entitlements):
                    self.assertEqual(asc_profile.supports_profile(
                        {}, "TEAM", "com.example.app.widgets", "group.example"), expected)
                    self.assertFalse(asc_profile.supports_profile(
                        {}, "OTHER", "com.example.app.widgets", "group.example"))
                    self.assertFalse(asc_profile.supports_profile(
                        {}, "TEAM", "com.example.app", "group.example"))

    def test_stale_profile_is_replaced_and_new_profile_validated(self):
        import base64
        import hashlib
        import sys
        import tempfile

        for widget in [False, True]:
            for valid_replacement in [False, True]:
                with self.subTest(widget=widget, valid_replacement=valid_replacement):
                    bundle_id = "com.example.app" + (".widgets" if widget else "")
                    stale = {"id": "old", "attributes": {
                        "name": "Release", "profileState": "ACTIVE"}, "relationships": {
                            "bundleId": {"data": {"id": "bundle"}},
                            "certificates": {"data": [{"id": "cert"}]}}}
                    fresh = {"id": "new", "attributes": {"name": "New Release",
                             "profileContent": base64.b64encode(b"profile").decode()}}
                    good = self.entitlements(bundle_id)
                    old = {k: v for k, v in good.items() if k != "com.apple.security.application-groups"}
                    cert = {"id": "cert", "attributes": {
                        "certificateContent": base64.b64encode(b"cert").decode(), "serialNumber": "1"}}
                    args = ["asc_profile.py", "--key-id", "key", "--issuer-id", "issuer",
                            "--key-path", "key.p8", "--team", "TEAM", "--bundle-id", bundle_id,
                            "--name", "Release", "--app-group", "group.example"]
                    if not widget:
                        args += ["--cloudkit-container", "iCloud.example"]
                    with tempfile.TemporaryDirectory() as directory, \
                         patch.object(sys, "argv", args), \
                         patch.object(asc_profile, "local_distribution_identities", return_value={hashlib.sha1(b"cert").hexdigest().upper(): b"cert"}), \
                         patch.object(asc_profile, "jwt", return_value="token"), \
                         patch.object(asc_profile, "Client") as client, \
                         patch.object(asc_profile, "profile_entitlements", side_effect=lambda p: good if p["id"] == "new" and valid_replacement else old), \
                         patch.object(asc_profile, "PROFILE_DIRS", [directory]), \
                         patch.object(asc_profile.subprocess, "run") as run:
                        api = client.return_value
                        api.get_all.side_effect = [[cert], [{"id": "bundle", "attributes": {"identifier": bundle_id}}], [stale]]
                        api.call.return_value = {"data": fresh}
                        run.return_value.stdout = b'<key>UUID</key><string>profile-uuid</string>'
                        if valid_replacement:
                            asc_profile.main()
                            from pathlib import Path
                            self.assertEqual((Path(directory) / "profile-uuid.mobileprovision").read_bytes(), b"profile")
                        else:
                            with self.assertRaises(SystemExit):
                                asc_profile.main()
                            run.assert_not_called()
                        api.call.assert_called_once()
                        self.assertEqual(api.call.call_args.args[:2], ("POST", "/profiles"))
