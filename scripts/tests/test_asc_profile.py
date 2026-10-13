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
