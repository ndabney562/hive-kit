#!/usr/bin/env python3
"""Checks that a Hive app can upload to TestFlight: its bundle ID is registered with Apple and App Store Connect has
an app record for it. Every new Hive app missed this step (Noah, 2026-11-09), so testflight.sh runs it before the
archive and hive-test-all.sh runs it for every iPhone repo.

Usage: python3 -I asc_check.py <app repo dir> [--no-register]
  Reads PRODUCT_BUNDLE_IDENTIFIER from the .xcodeproj in <repo> (or the shallowest one up to 3 folders down) and the
  API key from Config/Signing.xcconfig next to it
  (ASC_KEY_ID, ASC_ISSUER_ID; key file ~/.appstoreconnect/private_keys/AuthKey_<id>.p8).
  A missing bundle ID is registered (what Xcode would do); --no-register only reports it. It also checks for an
  internal TestFlight group with a tester (read only): without one, builds never reach Noah (2026-11-13).
Exit: 0 ready, 1 not ready (the browser steps are printed), 2 no API key or bundle ID to check with.
Stdlib only; the token is made with openssl and kept in memory. Tests: HIVE_ASC_FAKE=<json file> answers requests
from {"GET <path>": [status, body], ...} instead of Apple, and logs POST bodies to HIVE_ASC_FAKE_LOG.
"""
import base64, glob, json, os, re, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

API = "https://api.appstoreconnect.apple.com"


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der):
    """openssl gives an ECDSA signature as DER; a JWT wants r and s as 32 bytes each."""
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[i] != 2:
            raise ValueError("not a DER ECDSA signature")
        n = der[i + 1]
        out += der[i + 2:i + 2 + n].lstrip(b"\0").rjust(32, b"\0")
        i += 2 + n
    return out


def token(key_id, issuer, key_file):
    now = int(time.time())
    head = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    body = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}).encode())
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_file], input=f"{head}.{body}".encode(),
                         capture_output=True, check=True).stdout
    return f"{head}.{body}.{b64(der_to_raw(sig))}"


class Client:
    def __init__(self, key_id, issuer, key_file):
        self.auth = (key_id, issuer, key_file)
        fake = os.environ.get("HIVE_ASC_FAKE")
        self.fake = json.load(open(fake)) if fake else None

    def call(self, method, path, body=None):
        if self.fake is not None:
            if method == "POST":
                with open(os.environ["HIVE_ASC_FAKE_LOG"], "a") as f:
                    f.write(json.dumps({"path": path, "body": body}) + "\n")
            status, data = self.fake.get(f"{method} {path}", [404, {"errors": [{"detail": "not in fake"}]}])
            return status, data
        req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                     headers={"Authorization": "Bearer " + token(*self.auth),
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, parse(r.read())
        except urllib.error.HTTPError as e:
            return e.code, {"errors": [{"detail": e.read().decode()[:300]}]}


def parse(raw):
    """A response body as JSON; Apple's 204 (relationship updates) has none."""
    return json.loads(raw) if raw.strip() else {}


def setting(text, name):
    m = re.findall(rf"^[ \t]*{name}[ \t]*=[ \t]*(\S+)", text, re.M)
    return m[-1] if m else ""


SKIP_DIRS = {".build", "build", "DerivedData", "node_modules", ".git", "Pods"}


def project_dir(repo):
    """The folder holding the app's .xcodeproj: the repo itself, or the shallowest subfolder up to 3 levels down
    (HiveMind keeps it in apps/ios; missed until 2026-11-09). Build output folders are skipped."""
    for depth in range(4):
        found = []
        for root, dirs, _ in os.walk(repo):
            level = os.path.relpath(root, repo).count(os.sep) + (root != repo)
            dirs[:] = [] if level >= depth else [d for d in dirs if d not in SKIP_DIRS and not d.endswith(".xcodeproj")]
            if level == depth and glob.glob(os.path.join(root, "*.xcodeproj")):
                found.append(root)
        if found:
            return sorted(found)[0]
    return repo


def bundle_id(repo):
    ids = set()
    for p in glob.glob(os.path.join(repo, "*.xcodeproj", "project.pbxproj")):
        ids |= set(re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = \"?([A-Za-z0-9.\-]+)\"?;", open(p).read()))
    apps = sorted(i for i in ids if not re.search(r"\.(ui)?tests$", i, re.I))
    return min(apps, key=len) if apps else ""


def name_of(repo):
    projects = glob.glob(os.path.join(repo, "*.xcodeproj"))
    return os.path.basename(projects[0])[:-len(".xcodeproj")] if projects else os.path.basename(repo)


def main(argv):
    if not argv or argv[0].startswith("-"):
        print(__doc__.strip().splitlines()[3], file=sys.stderr)
        return 2
    repo, register = project_dir(os.path.abspath(argv[0])), "--no-register" not in argv
    bid, name = bundle_id(repo), name_of(repo)
    if not bid:
        print(f"asc_check: no PRODUCT_BUNDLE_IDENTIFIER in {repo}/*.xcodeproj", file=sys.stderr)
        return 2
    signing = os.environ.get("HIVE_SIGNING", os.path.join(repo, "Config", "Signing.xcconfig"))
    text = open(signing).read() if os.path.exists(signing) else ""
    key_id, issuer = setting(text, "ASC_KEY_ID"), setting(text, "ASC_ISSUER_ID")
    key_file = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    if not (key_id and issuer and os.path.exists(key_file)):
        print(f"asc_check: {name}: can't check {bid}: set ASC_KEY_ID and ASC_ISSUER_ID in {signing} "
              f"and put the key in {key_file}.", file=sys.stderr)
        return 2
    c = Client(key_id, issuer, key_file)
    q = urllib.parse.quote(bid, safe="")
    status, data = c.call("GET", f"/v1/bundleIds?filter[identifier]={q}&fields[bundleIds]=identifier")
    if status != 200:
        print(f"asc_check: {name}: Apple answered {status} for the bundle ID: {data}", file=sys.stderr)
        return 1
    if not any(d["attributes"]["identifier"] == bid for d in data.get("data", [])):
        if not register:
            print(f"NOT READY {name}: bundle ID {bid} is not registered (run without --no-register).")
            return 1
        status, data = c.call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": bid, "name": name, "platform": "IOS"}}})
        if status != 201:
            print(f"asc_check: {name}: registering {bid} failed ({status}): {data}", file=sys.stderr)
            return 1
        print(f"Registered bundle ID {bid} for {name}.")
    status, data = c.call("GET", f"/v1/apps?filter[bundleId]={q}&fields[apps]=bundleId,name")
    if status != 200:
        print(f"asc_check: {name}: Apple answered {status} for the app record: {data}", file=sys.stderr)
        return 1
    apps = [d for d in data.get("data", []) if d["attributes"]["bundleId"] == bid]
    if not apps:
        print(f"NOT READY {name}: App Store Connect has no app for {bid}. Apple's API can't create one, so Claude "
              f"makes it in the signed-in built-in browser (about 3 min):\n"
              f"  1. appstoreconnect.apple.com > Apps > + > New App\n"
              f"  2. Platform iOS; Name {name}; Language English (U.S.); Bundle ID {bid}; SKU {name.lower()}; "
              f"User Access Full Access\n"
              f"  3. Tap Create")
        return 1
    status, data = c.call("GET", f"/v1/betaGroups?filter[app]={apps[0]['id']}&filter[isInternalGroup]=true"
                                 f"&include=betaTesters&fields[betaGroups]=name,betaTesters&limit=50")
    if status != 200:
        print(f"asc_check: {name}: Apple answered {status} for the TestFlight groups: {data}", file=sys.stderr)
        return 1
    if not any(g.get("relationships", {}).get("betaTesters", {}).get("data") for g in data.get("data", [])):
        print(f"NOT READY {name}: no internal TestFlight group with a tester, so builds never reach Noah's iPhone. "
              f"Claude makes it in the signed-in built-in browser (Noah's yes first; about 2 min):\n"
              f"  1. appstoreconnect.apple.com > Apps > {name} > TestFlight > Internal Testing +\n"
              f"  2. Group name Me, keep Enable automatic distribution ticked > Create\n"
              f"  3. Testers + > tick Noah > Add")
        return 1
    print(f"READY {name}: {bid} is registered, has an App Store Connect app and an internal tester group.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
