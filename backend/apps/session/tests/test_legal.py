import os
from unittest.mock import patch

from django.test import SimpleTestCase

from apps.session.legal import get_current_consent_versions, get_current_legal_documents


LEGAL_ENV_KEYS = [
    "PRIVACY_POLICY_VERSION",
    "PRIVACY_POLICY_URL",
    "PERSONAL_DATA_CONSENT_VERSION",
    "PERSONAL_DATA_CONSENT_URL",
    "LEGAL_CONTACT_EMAIL",
]


class LegalDocumentsTests(SimpleTestCase):
    def test_returns_defaults_when_environment_is_missing(self):
        with patch.dict(os.environ, {}, clear=False):
            for key in LEGAL_ENV_KEYS:
                os.environ.pop(key, None)

            documents = get_current_legal_documents()

        self.assertEqual(documents["privacy_policy"]["version"], "2026-01")
        self.assertEqual(documents["privacy_policy"]["url"], "http://localhost:3000/legal/privacy")
        self.assertEqual(documents["personal_data_consent"]["version"], "2026-01")
        self.assertEqual(
            documents["personal_data_consent"]["url"],
            "http://localhost:3000/legal/consent",
        )
        self.assertEqual(documents["contact_email"], "privacy@umclick.local")

    def test_returns_configured_versions_and_urls(self):
        with patch.dict(
            os.environ,
            {
                "PRIVACY_POLICY_VERSION": "2026-05",
                "PRIVACY_POLICY_URL": "https://umclick.example/privacy",
                "PERSONAL_DATA_CONSENT_VERSION": "2026-06",
                "PERSONAL_DATA_CONSENT_URL": "https://umclick.example/consent",
                "LEGAL_CONTACT_EMAIL": "privacy@umclick.example",
            },
        ):
            documents = get_current_legal_documents()
            versions = get_current_consent_versions()

        self.assertEqual(documents["privacy_policy"]["version"], "2026-05")
        self.assertEqual(documents["privacy_policy"]["url"], "https://umclick.example/privacy")
        self.assertEqual(documents["personal_data_consent"]["version"], "2026-06")
        self.assertEqual(documents["personal_data_consent"]["url"], "https://umclick.example/consent")
        self.assertEqual(documents["contact_email"], "privacy@umclick.example")
        self.assertEqual(versions, ("2026-05", "2026-06"))

    def test_blank_environment_values_fall_back_to_defaults(self):
        with patch.dict(
            os.environ,
            {
                "PRIVACY_POLICY_VERSION": " ",
                "PERSONAL_DATA_CONSENT_VERSION": "",
                "LEGAL_CONTACT_EMAIL": "   ",
            },
        ):
            documents = get_current_legal_documents()

        self.assertEqual(documents["privacy_policy"]["version"], "2026-01")
        self.assertEqual(documents["personal_data_consent"]["version"], "2026-01")
        self.assertEqual(documents["contact_email"], "privacy@umclick.local")
