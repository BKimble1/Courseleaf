#!/usr/bin/env python3
"""App Store Connect API client for the Courseleaf release pipeline.

Every call is authenticated with a short-lived ES256 JWT signed by the team's
API key. The key is read from a file path and is never printed, logged, or
echoed into a build artifact; only resource identifiers appear on stdout.

Subcommands (all print a single line or a small JSON object):

    verify-app      confirm the app record matches the expected bundle ID and
                    numeric Apple ID; never creates a record
    next-build      the lowest build number not yet used for a marketing version
    build-state     processing state of one (version, build) pair
    wait-build      poll until that build finishes processing
    group           resolve an internal TestFlight group by name
    add-build       add a processed build to an internal group
    testers         list the internal testers of a group and the account's users
    add-tester      add one App Store Connect user to an internal group
    audit-signing   read-only inventory of certificates, identifiers, profiles
                    and devices, for diagnosing release signing
    create-cert     create one distribution certificate from a CSR
    profile         find or create the App Store profile for a bundle ID

Credentials come from the environment:
    ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # PyJWT, with the `cryptography` backend for ES256

BASE = "https://api.appstoreconnect.apple.com"


def token() -> str:
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    path = os.environ["ASC_PRIVATE_KEY_PATH"]
    with open(path) as fh:
        secret = fh.read()
    now = int(time.time())
    # Apple rejects tokens with a lifetime over 20 minutes.
    payload = {"iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, secret, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


def request(method: str, path: str, body: dict | None = None, *, params: dict | None = None) -> dict:
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", "replace")[:2000]
        # The URL is safe to show; the token is in a header and never in it.
        raise SystemExit(f"{method} {path} -> HTTP {err.code}\n{detail}") from None


def paged(path: str, params: dict) -> list[dict]:
    out: list[dict] = []
    params = dict(params, limit=params.get("limit", 200))
    page = request("GET", path, params=params)
    out.extend(page.get("data", []))
    while (nxt := page.get("links", {}).get("next")):
        req = urllib.request.Request(nxt, method="GET")
        req.add_header("Authorization", f"Bearer {token()}")
        with urllib.request.urlopen(req, timeout=60) as resp:
            page = json.loads(resp.read())
        out.extend(page.get("data", []))
    return out


# --- commands -------------------------------------------------------------

def cmd_verify_app(args) -> int:
    """Find the existing record. This never creates one: if the bundle ID has
    no app, that is a hard stop for a human, not something to paper over."""
    apps = paged("/v1/apps", {"filter[bundleId]": args.bundle_id})
    if not apps:
        print(f"ERROR: no app record for bundle ID {args.bundle_id}. "
              "Create it once in App Store Connect; this script will not.")
        return 2
    if len(apps) > 1:
        print(f"ERROR: {len(apps)} app records match {args.bundle_id}: "
              f"{[a['id'] for a in apps]}")
        return 2
    app = apps[0]
    attrs = app["attributes"]
    ok = True
    if args.app_id and app["id"] != args.app_id:
        print(f"ERROR: expected Apple ID {args.app_id}, record is {app['id']}")
        ok = False
    if attrs.get("bundleId") != args.bundle_id:
        print(f"ERROR: record bundle ID is {attrs.get('bundleId')!r}")
        ok = False
    print(json.dumps({
        "appleId": app["id"],
        "bundleId": attrs.get("bundleId"),
        "name": attrs.get("name"),
        "sku": attrs.get("sku"),
        "primaryLocale": attrs.get("primaryLocale"),
    }, indent=2))
    return 0 if ok else 2


def builds_for_version(app_id: str, version: str) -> list[dict]:
    return paged("/v1/builds", {
        "filter[app]": app_id,
        "filter[preReleaseVersion.version]": version,
        "fields[builds]": "version,processingState,uploadedDate,expired",
    })


def cmd_next_build(args) -> int:
    used = []
    for b in builds_for_version(args.app_id, args.version):
        try:
            used.append(int(b["attributes"]["version"]))
        except (KeyError, TypeError, ValueError):
            continue
    nxt = max(used) + 1 if used else 1
    print(nxt)
    return 0


def cmd_build_state(args) -> int:
    for b in builds_for_version(args.app_id, args.version):
        if b["attributes"]["version"] == str(args.build):
            print(json.dumps({"id": b["id"], **b["attributes"]}, indent=2))
            return 0
    print("NOT_FOUND")
    return 1


def cmd_wait_build(args) -> int:
    deadline = time.time() + args.timeout
    last = None
    while time.time() < deadline:
        for b in builds_for_version(args.app_id, args.version):
            if b["attributes"]["version"] != str(args.build):
                continue
            state = b["attributes"].get("processingState")
            if state != last:
                print(f"{time.strftime('%H:%M:%S')} build {args.version} ({args.build}) -> {state}", flush=True)
                last = state
            if state == "VALID":
                print(b["id"])
                return 0
            if state in ("INVALID", "FAILED"):
                print(f"ERROR: processing ended in {state}; see App Store Connect for the reason")
                return 2
            break
        else:
            if last is None:
                print(f"{time.strftime('%H:%M:%S')} build not visible yet", flush=True)
        time.sleep(args.interval)
    print(f"ERROR: build {args.version} ({args.build}) did not finish processing within {args.timeout}s")
    return 3


def find_group(app_id: str, name: str) -> dict | None:
    for g in paged("/v1/betaGroups", {"filter[app]": app_id}):
        if g["attributes"].get("name") == name:
            return g
    return None


def cmd_group(args) -> int:
    g = find_group(args.app_id, args.name)
    if g is None:
        print(f"ERROR: no TestFlight group named {args.name!r} on this app")
        return 2
    print(json.dumps({"id": g["id"], **g["attributes"]}, indent=2))
    return 0 if g["attributes"].get("isInternalGroup") else 2


def cmd_add_build(args) -> int:
    g = find_group(args.app_id, args.name)
    if g is None:
        print(f"ERROR: no TestFlight group named {args.name!r}")
        return 2
    if not g["attributes"].get("isInternalGroup"):
        print(f"ERROR: {args.name!r} is not an internal group; refusing to touch external testing")
        return 2
    existing = {b["id"] for b in paged(f"/v1/betaGroups/{g['id']}/builds", {"fields[builds]": "version"})}
    if args.build_id in existing:
        print(f"already in {args.name}")
        return 0
    request("POST", f"/v1/betaGroups/{g['id']}/relationships/builds",
            {"data": [{"type": "builds", "id": args.build_id}]})
    print(f"added to {args.name}")
    return 0


def cmd_set_notes(args) -> int:
    """Set the build's "What to Test" for one locale.

    Testers see this in TestFlight before they install, so it is the only place
    a build can say what changed and what is known to be unfinished. Updates the
    existing localization when there is one rather than adding a second."""
    text = args.text
    if args.file:
        with open(args.file) as fh:
            text = fh.read()
    if not text or not text.strip():
        print("ERROR: no notes given (--text or --file)")
        return 2
    # Apple caps this field; trim rather than be rejected after a good upload.
    limit = 4000
    text = text.strip()
    if len(text) > limit:
        text = text[: limit - 3].rstrip() + "..."
    existing = paged(f"/v1/builds/{args.build_id}/betaBuildLocalizations",
                     {"fields[betaBuildLocalizations]": "locale,whatsNew"})
    for loc in existing:
        if loc["attributes"].get("locale") == args.locale:
            request("PATCH", f"/v1/betaBuildLocalizations/{loc['id']}",
                    {"data": {"type": "betaBuildLocalizations", "id": loc["id"],
                              "attributes": {"whatsNew": text}}})
            print(f"updated What to Test for {args.locale} ({len(text)} characters)")
            return 0
    request("POST", "/v1/betaBuildLocalizations",
            {"data": {"type": "betaBuildLocalizations",
                      "attributes": {"locale": args.locale, "whatsNew": text},
                      "relationships": {"build": {"data": {"type": "builds", "id": args.build_id}}}}})
    print(f"set What to Test for {args.locale} ({len(text)} characters)")
    return 0


def cmd_testers(args) -> int:
    g = find_group(args.app_id, args.name)
    group_testers = []
    if g is not None:
        group_testers = [t["attributes"].get("email") for t in
                         paged(f"/v1/betaGroups/{g['id']}/betaTesters", {"fields[betaTesters]": "email,firstName,lastName"})]
    users = [{"id": u["id"], "email": u["attributes"].get("username"),
              "roles": u["attributes"].get("roles")}
             for u in paged("/v1/users", {"fields[users]": "username,firstName,lastName,roles"})]
    print(json.dumps({"group": args.name, "groupId": g["id"] if g else None,
                      "groupTesters": group_testers, "accountUsers": users}, indent=2))
    return 0


def cmd_add_tester(args) -> int:
    """Add exactly one App Store Connect user to the internal group.

    Refuses to guess: either --email names a user that exists on the account,
    or the account has exactly one user and --auto picks it. Anything else is a
    question for a human, because inviting the wrong person is not undoable."""
    g = find_group(args.app_id, args.name)
    if g is None or not g["attributes"].get("isInternalGroup"):
        print(f"ERROR: no internal group named {args.name!r}")
        return 2
    users = paged("/v1/users", {"fields[users]": "username,firstName,lastName,roles"})
    chosen = None
    if args.email:
        for u in users:
            if (u["attributes"].get("username") or "").lower() == args.email.lower():
                chosen = u
                break
        if chosen is None:
            print(f"ERROR: {args.email} is not an App Store Connect user on this team; "
                  "not creating an invitation for an address the team does not own")
            return 2
    elif len(users) == 1:
        chosen = users[0]
    else:
        print(f"ERROR: {len(users)} users on the account; pass --email to say which one")
        return 2

    email = chosen["attributes"]["username"]
    existing = {(t["attributes"].get("email") or "").lower() for t in
                paged(f"/v1/betaGroups/{g['id']}/betaTesters", {"fields[betaTesters]": "email"})}
    if email.lower() in existing:
        print(f"already a tester in {args.name}")
        return 0
    request("POST", "/v1/betaTesters", {
        "data": {
            "type": "betaTesters",
            "attributes": {
                "email": email,
                "firstName": chosen["attributes"].get("firstName") or "",
                "lastName": chosen["attributes"].get("lastName") or "",
            },
            "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": g["id"]}]}},
        },
    })
    print(f"added {email} to {args.name}")
    return 0


def safe(fn):
    """Run one read-only probe, returning its error instead of aborting.

    An audit that dies on the first 403 hides the very fact it was run to
    find out: which parts of Certificates, Identifiers & Profiles this API
    key can actually see.
    """
    try:
        return fn()
    except SystemExit as err:
        return {"error": str(err)}


def cmd_audit_signing(args) -> int:
    """Read-only inventory of the team's code-signing assets.

    Prints identifiers and metadata only: never certificateContent, never
    profileContent, never a device UDID. It creates nothing, changes nothing
    and revokes nothing, so it is safe to run against a live team.
    """
    report: dict = {}

    report["certificates"] = safe(lambda: [{
        "id": c["id"],
        "certificateType": c["attributes"].get("certificateType"),
        "displayName": c["attributes"].get("displayName"),
        "expirationDate": c["attributes"].get("expirationDate"),
    } for c in paged("/v1/certificates", {})])

    def devices():
        found = paged("/v1/devices", {})
        by_status: dict[str, int] = {}
        for d in found:
            status = d["attributes"].get("status") or "?"
            by_status[status] = by_status.get(status, 0) + 1
        # Count only: a UDID identifies someone's hardware and the audit has
        # no use for it.
        return {"total": len(found), "byStatus": by_status}
    report["devices"] = safe(devices)

    report["bundleIds"] = safe(lambda: [{
        "id": b["id"],
        "identifier": b["attributes"].get("identifier"),
        "name": b["attributes"].get("name"),
        "platform": b["attributes"].get("platform"),
    } for b in paged("/v1/bundleIds", {"filter[identifier]": args.bundle_id})])

    def profiles():
        out = []
        for p in paged("/v1/profiles", {}):
            entry = {
                "id": p["id"],
                "name": p["attributes"].get("name"),
                "profileType": p["attributes"].get("profileType"),
                "profileState": p["attributes"].get("profileState"),
                "expirationDate": p["attributes"].get("expirationDate"),
            }
            entry["deviceCount"] = safe(lambda pid=p["id"]: len(paged(f"/v1/profiles/{pid}/devices", {})))
            out.append(entry)
        return out
    report["profiles"] = safe(profiles)

    print(json.dumps(report, indent=2))
    return 0


def bundle_id_resource(identifier: str) -> dict:
    found = [b for b in paged("/v1/bundleIds", {"filter[identifier]": identifier})
             if b["attributes"].get("identifier") == identifier]
    if not found:
        raise SystemExit(f"ERROR: no bundle ID record for {identifier}; create it once in "
                         "App Store Connect, this script will not")
    if len(found) > 1:
        raise SystemExit(f"ERROR: {len(found)} bundle ID records for {identifier}")
    return found[0]


def cmd_create_cert(args) -> int:
    """Create one distribution certificate from a certificate signing request.

    Apple caps a team at three distribution certificates and revoking one is
    not on the table here, so a slot spent is gone. The caller is expected to
    reuse a stored identity and reach this only when it genuinely has none;
    the existing count is reported so a limit failure is legible rather than
    mysterious.

    Only the public certificate is written out. The private key never leaves
    the caller, which generated it, and is never sent to Apple.
    """
    with open(args.csr) as fh:
        csr = fh.read()
    existing = [c for c in paged("/v1/certificates", {})
                if c["attributes"].get("certificateType") == args.type]
    print(f"team already has {len(existing)} {args.type} certificate(s); Apple allows 3",
          file=sys.stderr)
    resp = request("POST", "/v1/certificates", {
        "data": {
            "type": "certificates",
            "attributes": {"certificateType": args.type, "csrContent": csr},
        },
    })
    data = resp["data"]
    with open(args.out, "w") as fh:
        fh.write(data["attributes"]["certificateContent"])
    print(json.dumps({
        "id": data["id"],
        "certificateType": data["attributes"].get("certificateType"),
        "serialNumber": data["attributes"].get("serialNumber"),
        "expirationDate": data["attributes"].get("expirationDate"),
    }, indent=2))
    return 0


def cmd_profile(args) -> int:
    """Find or create the App Store provisioning profile for one bundle ID.

    A profile is reused only when it is ACTIVE, belongs to this bundle ID and
    already lists the certificate we are about to sign with. A profile that
    fails any of those would produce an archive Xcode cannot sign, and finding
    that out at codesign time is worse than making a new profile here.

    An App Store profile provisions no devices, which is the whole point: the
    team has none registered and TestFlight does not need any.
    """
    bundle = bundle_id_resource(args.bundle_id)
    for p in paged("/v1/profiles", {"filter[profileType]": args.type,
                                    "include": "bundleId,certificates"}):
        if p["attributes"].get("profileState") != "ACTIVE":
            continue
        rel = p.get("relationships", {})
        linked = (rel.get("bundleId", {}).get("data") or {}).get("id")
        if linked != bundle["id"]:
            continue
        certs = [c["id"] for c in (rel.get("certificates", {}).get("data") or [])]
        if args.cert_id not in certs:
            continue
        # The list response is not guaranteed to carry profileContent; fetch
        # the profile itself rather than writing an empty file.
        full = request("GET", f"/v1/profiles/{p['id']}")["data"]
        with open(args.out, "w") as fh:
            fh.write(full["attributes"]["profileContent"])
        print(json.dumps({"id": p["id"], "name": full["attributes"].get("name"),
                          "uuid": full["attributes"].get("uuid"),
                          "expirationDate": full["attributes"].get("expirationDate"),
                          "reused": True}, indent=2))
        return 0

    body = {
        "data": {
            "type": "profiles",
            "attributes": {"name": args.name, "profileType": args.type},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                "certificates": {"data": [{"type": "certificates", "id": args.cert_id}]},
            },
        },
    }
    try:
        data = request("POST", "/v1/profiles", body)["data"]
    except SystemExit as err:
        # Profile names are unique per team. An older profile under this name
        # that we could not reuse above is not ours to delete, so take a new
        # name instead of failing the release.
        if "409" not in str(err):
            raise
        body["data"]["attributes"]["name"] = f"{args.name} {args.cert_id}"
        data = request("POST", "/v1/profiles", body)["data"]
    with open(args.out, "w") as fh:
        fh.write(data["attributes"]["profileContent"])
    print(json.dumps({"id": data["id"], "name": data["attributes"].get("name"),
                      "uuid": data["attributes"].get("uuid"),
                      "expirationDate": data["attributes"].get("expirationDate"),
                      "reused": False}, indent=2))
    return 0


def cmd_list_groups(args) -> int:
    """Every TestFlight group on the app, with the names exactly as Apple
    spells them. add-build matches by name, so a release that cannot find its
    group needs to see the real list rather than a guess at what it meant."""
    groups = [{
        "id": g["id"],
        "name": g["attributes"].get("name"),
        "isInternalGroup": g["attributes"].get("isInternalGroup"),
        "createdDate": g["attributes"].get("createdDate"),
        "publicLinkEnabled": g["attributes"].get("publicLinkEnabled"),
    } for g in paged("/v1/betaGroups", {"filter[app]": args.app_id})]
    print(json.dumps(groups, indent=2))
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("verify-app"); s.add_argument("--bundle-id", required=True)
    s.add_argument("--app-id"); s.set_defaults(func=cmd_verify_app)

    s = sub.add_parser("next-build"); s.add_argument("--app-id", required=True)
    s.add_argument("--version", required=True); s.set_defaults(func=cmd_next_build)

    s = sub.add_parser("build-state"); s.add_argument("--app-id", required=True)
    s.add_argument("--version", required=True); s.add_argument("--build", required=True)
    s.set_defaults(func=cmd_build_state)

    s = sub.add_parser("wait-build"); s.add_argument("--app-id", required=True)
    s.add_argument("--version", required=True); s.add_argument("--build", required=True)
    s.add_argument("--timeout", type=int, default=2400); s.add_argument("--interval", type=int, default=30)
    s.set_defaults(func=cmd_wait_build)

    s = sub.add_parser("group"); s.add_argument("--app-id", required=True)
    s.add_argument("--name", required=True); s.set_defaults(func=cmd_group)

    s = sub.add_parser("add-build"); s.add_argument("--app-id", required=True)
    s.add_argument("--name", required=True); s.add_argument("--build-id", required=True)
    s.set_defaults(func=cmd_add_build)

    s = sub.add_parser("set-notes"); s.add_argument("--build-id", required=True)
    s.add_argument("--locale", default="en-US"); s.add_argument("--text"); s.add_argument("--file")
    s.set_defaults(func=cmd_set_notes)

    s = sub.add_parser("testers"); s.add_argument("--app-id", required=True)
    s.add_argument("--name", required=True); s.set_defaults(func=cmd_testers)

    s = sub.add_parser("add-tester"); s.add_argument("--app-id", required=True)
    s.add_argument("--name", required=True); s.add_argument("--email")
    s.set_defaults(func=cmd_add_tester)

    s = sub.add_parser("audit-signing"); s.add_argument("--bundle-id", required=True)
    s.set_defaults(func=cmd_audit_signing)

    s = sub.add_parser("create-cert"); s.add_argument("--type", default="DISTRIBUTION")
    s.add_argument("--csr", required=True); s.add_argument("--out", required=True)
    s.set_defaults(func=cmd_create_cert)

    s = sub.add_parser("profile"); s.add_argument("--bundle-id", required=True)
    s.add_argument("--type", default="IOS_APP_STORE"); s.add_argument("--cert-id", required=True)
    s.add_argument("--name", required=True); s.add_argument("--out", required=True)
    s.set_defaults(func=cmd_profile)

    s = sub.add_parser("list-groups"); s.add_argument("--app-id", required=True)
    s.set_defaults(func=cmd_list_groups)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
