from __future__ import annotations

import os


def _env(name: str, default: str) -> str:
    value = os.getenv(name, default).strip()
    return value or default


def get_current_legal_documents() -> dict:
    privacy_version = _env("PRIVACY_POLICY_VERSION", "2026-01")
    consent_version = _env("PERSONAL_DATA_CONSENT_VERSION", "2026-01")

    return {
        "privacy_policy": {
            "version": privacy_version,
            "url": _env("PRIVACY_POLICY_URL", "http://localhost:3000/legal/privacy"),
        },
        "personal_data_consent": {
            "version": consent_version,
            "url": _env("PERSONAL_DATA_CONSENT_URL", "http://localhost:3000/legal/consent"),
        },
        "contact_email": _env("LEGAL_CONTACT_EMAIL", "privacy@umclick.local"),
    }


def get_current_consent_versions() -> tuple[str, str]:
    legal_documents = get_current_legal_documents()
    privacy_version = legal_documents["privacy_policy"]["version"]
    consent_version = legal_documents["personal_data_consent"]["version"]
    return privacy_version, consent_version
