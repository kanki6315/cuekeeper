#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Make sure an App Store provisioning profile exists for the local Apple
Distribution certificate, install it, and print its name.

Used by release.sh. Why this exists: when xcodebuild authenticates with an App
Store Connect API key, its automatic signing only considers *cloud-managed*
distribution certificates, which need an Admin key. With a classic Apple
Distribution certificate in the keychain (Xcode → Settings → Accounts → Manage
Certificates) the export has to be signed manually, and manual signing needs a
profile. This script keeps that profile current through the App Store Connect
API so nobody has to visit the developer portal: it finds the portal
certificate matching the keychain identity, reuses an active App Store profile
that contains it, or creates one, then installs it where Xcode looks.

Only the standard library plus the `openssl` and `security` CLIs, so it runs on
any Mac. Usage:

  asc_profile.py --key-id ID --issuer-id UUID --key-path AuthKey.p8 \
                 --team TEAMID --bundle-id com.example.app --name "Example App Store"
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
PROFILE_DIRS = [
    os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),  # Xcode 16+
    os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles"),  # older Xcode + xcodebuild fallback
]


def die(msg):
    print(f"asc_profile: {msg}", file=sys.stderr)
    sys.exit(1)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def jwt(key_id, issuer_id, key_path) -> str:
    """ES256 JWT for the App Store Connect API, signed with openssl."""
    now = int(dt.datetime.now(dt.timezone.utc).timestamp())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64url(json.dumps({"iss": issuer_id, "iat": now, "exp": now + 600,
                                 "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{payload}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing_input, capture_output=True, check=True).stdout
    # DER ECDSA signature → raw r||s (32 bytes each), as JWS requires.
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 3
    r_len = der[i + 1]
    r = der[i + 2:i + 2 + r_len]
    j = i + 2 + r_len
    s_len = der[j + 1]
    s = der[j + 2:j + 2 + s_len]
    raw = r[-32:].rjust(32, b"\0") + s[-32:].rjust(32, b"\0")
    return f"{header}.{payload}.{b64url(raw)}"


class Client:
    def __init__(self, token):
        self.token = token

    def call(self, method, path, body=None):
        req = urllib.request.Request(API + path, method=method,
                                     headers={"Authorization": f"Bearer {self.token}",
                                              "Content-Type": "application/json"})
        data = json.dumps(body).encode() if body is not None else None
        try:
            with urllib.request.urlopen(req, data) as resp:
                text = resp.read()
                return json.loads(text) if text else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            try:
                errs = json.loads(detail).get("errors", [])
                detail = "; ".join(f"{x.get('title')}: {x.get('detail')}" for x in errs) or detail
            except ValueError:
                pass
            die(f"{method} {path} → HTTP {e.code}: {detail}")

    def get_all(self, path):
        items = []
        while path:
            page = self.call("GET", path)
            items += page.get("data", [])
            nxt = page.get("links", {}).get("next")
            path = nxt[len(API):] if nxt else None
        return items


def local_distribution_identities() -> dict:
    """SHA-1 → subject for keychain Apple Distribution certs that have a private key."""
    ids = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                         capture_output=True, text=True).stdout
    with_key = {m.group(1).upper() for m in re.finditer(r"\b([0-9A-F]{40})\b\s+\"Apple Distribution:", ids)}
    pem = subprocess.run(["security", "find-certificate", "-a", "-c", "Apple Distribution", "-p"],
                         capture_output=True, text=True).stdout
    found = {}
    for block in re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", pem, re.S):
        der = base64.b64decode("".join(block.split()))
        sha1 = hashlib.sha1(der).hexdigest().upper()
        if sha1 in with_key:
            found[sha1] = der
    return found


def profile_entitlements(profile):
    content = base64.b64decode(profile["attributes"]["profileContent"])
    with tempfile.NamedTemporaryFile(suffix=".mobileprovision") as tmp:
        tmp.write(content)
        tmp.flush()
        result = subprocess.run(["security", "cms", "-D", "-i", tmp.name],
                                capture_output=True, check=True)
    return plistlib.loads(result.stdout).get("Entitlements", {})


def supports_cloudkit(profile, team, bundle_id, container):
    entitlements = profile_entitlements(profile)
    environment = entitlements.get("com.apple.developer.icloud-container-environment", [])
    if isinstance(environment, str):
        environment = [environment]
    return (entitlements.get("com.apple.developer.team-identifier") == team
            and entitlements.get("application-identifier") == f"{team}.{bundle_id}"
            and container in entitlements.get("com.apple.developer.icloud-container-identifiers", [])
            and "CloudKit" in entitlements.get("com.apple.developer.icloud-services", [])
            and "Production" in environment
            and entitlements.get("aps-environment") == "production")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key-id", required=True)
    ap.add_argument("--issuer-id", required=True)
    ap.add_argument("--key-path", required=True)
    ap.add_argument("--team", required=True)
    ap.add_argument("--bundle-id", required=True)
    ap.add_argument("--name", required=True, help="profile name to reuse or create")
    ap.add_argument("--cloudkit-container", required=True)
    a = ap.parse_args()

    local = local_distribution_identities()
    if not local:
        die("no Apple Distribution certificate with a private key in the keychain — "
            "Xcode → Settings → Accounts → Manage Certificates… → + → Apple Distribution")

    api = Client(jwt(a.key_id, a.issuer_id, a.key_path))

    # 1. The portal certificate that matches a keychain identity.
    cert = None
    for c in api.get_all("/certificates?filter[certificateType]=DISTRIBUTION&limit=200"):
        der = base64.b64decode(c["attributes"]["certificateContent"])
        if hashlib.sha1(der).hexdigest().upper() in local:
            cert = c
            break
    if cert is None:
        die("the keychain's Apple Distribution certificate is not on the portal for this team "
            "(revoked, or made for another team) — create a new one in Xcode → Manage Certificates…")
    cert_exp = cert["attributes"].get("expirationDate", "")
    log(f"certificate {cert['attributes']['serialNumber']} (expires {cert_exp[:10]})")

    # 2. The bundle ID record (Xcode registers it on the first signed build).
    bundles = api.get_all(f"/bundleIds?filter[identifier]={a.bundle_id}&limit=200")
    bundles = [b for b in bundles if b["attributes"]["identifier"] == a.bundle_id]
    if not bundles:
        bundle = api.call("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": a.bundle_id, "name": a.bundle_id.replace(".", " "), "platform": "IOS"}}})["data"]
        log(f"registered bundle ID {a.bundle_id}")
    else:
        bundle = bundles[0]

    # 3. An active App Store profile for that bundle ID containing that certificate.
    profiles = api.get_all("/profiles?filter[profileType]=IOS_APP_STORE&include=bundleId,certificates&limit=200")
    usable = None
    for p in profiles:
        rel = p.get("relationships", {})
        b = (rel.get("bundleId", {}).get("data") or {}).get("id")
        certs = {c["id"] for c in rel.get("certificates", {}).get("data", [])}
        if b == bundle["id"] and cert["id"] in certs and p["attributes"].get("profileState") == "ACTIVE" and supports_cloudkit(p, a.team, a.bundle_id, a.cloudkit_container):
            usable = p
            break
    if usable is None:
        # Preserve existing profiles, including profiles used by other projects.
        if any(p["attributes"]["name"] == a.name for p in profiles):
            a.name += " " + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d%H%M%S")
        usable = api.call("POST", "/profiles", {"data": {"type": "profiles",
            "attributes": {"name": a.name, "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]}}}})["data"]
        log(f"created profile {usable['attributes']['name']}")
    else:
        log(f"reusing profile {usable['attributes']['name']} (expires {usable['attributes'].get('expirationDate', '')[:10]})")

    if not supports_cloudkit(usable, a.team, a.bundle_id, a.cloudkit_container):
        die("profile lacks Cuekeeper's production CloudKit or push entitlements. "
            "Associate the iCloud container with the bundle ID in Certificates, Identifiers & Profiles first.")

    # 4. Install it where Xcode and xcodebuild look.
    content = base64.b64decode(usable["attributes"]["profileContent"])
    with tempfile.NamedTemporaryFile(suffix=".mobileprovision", delete=False) as tmp:
        tmp.write(content)
    plist = subprocess.run(["security", "cms", "-D", "-i", tmp.name], capture_output=True, check=True).stdout
    os.unlink(tmp.name)
    uuid = re.search(rb"<key>UUID</key>\s*<string>([^<]+)</string>", plist).group(1).decode()
    for d in PROFILE_DIRS:
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, f"{uuid}.mobileprovision"), "wb") as f:
            f.write(content)
    log(f"installed {uuid}.mobileprovision")
    print(usable["attributes"]["name"])


def log(msg):
    print(f"asc_profile: {msg}", file=sys.stderr)


if __name__ == "__main__":
    main()
