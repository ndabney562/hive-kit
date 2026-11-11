#!/usr/bin/env python3
"""TestFlight public link for a Hive app: external group + newest valid build + beta review submission.

Usage: python3 -I asc_public_link.py <repo> --group NAME --description TEXT --contact-from BUNDLE_ID [--dry-run]
       python3 -I asc_public_link.py <repo> --status --group NAME
--status reads only (never writes) and prints one JSON line: {"bundle", "build", "state", "public_link"}, where state is
Apple's betaReviewState of the newest processed build (WAITING_FOR_REVIEW, IN_REVIEW, APPROVED, REJECTED) or
NOT_SUBMITTED / NO_BUILD. HiveTempo's planner uses it to make the "reveal" task once Apple approves.

Copies the beta review contact and feedback email from another app of the same account (--contact-from), only
where the target has none (Noah's OK each time: it is his personal data). Prints the public link (it works once
Apple's beta review approves, usually within a day). Settings and key file as in asc_check.py.
Exit 0 = submitted or already in review/approved, 1 = Apple refused a step (printed), 2 = setup problem.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_check  # noqa: E402

CONTACT = ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")


class Steps:
    def __init__(self, client, dry):
        self.c, self.dry = client, dry

    def get(self, path):
        s, d = self.c.call("GET", path)
        if s != 200:
            raise SystemExit(self.fail("GET " + path, s, d))
        return d["data"]

    def write(self, method, path, body, what):
        print(("would " if self.dry else "") + what)
        if self.dry:
            return {"id": "dry", "attributes": {}}
        if self.c.fake is not None:
            with open(os.environ["HIVE_ASC_FAKE_LOG"], "a") as f:
                f.write(json.dumps({"method": method, "path": path, "body": body}) + "\n")
        s, d = self.c.call(method, path, body)
        if s not in (200, 201, 204):
            raise SystemExit(self.fail(what, s, d))
        return (d or {}).get("data") or {}

    @staticmethod
    def fail(what, status, data):
        print("asc_public_link: %s failed (%s): %s" % (what, status, json.dumps(data.get("errors", data))[:400]))
        return 1


def app_id(st, bundle):
    apps = st.get("/v1/apps?filter[bundleId]=%s" % bundle)
    if not apps:
        print("asc_public_link: no App Store Connect app for %s (run asc_check.py)" % bundle)
        raise SystemExit(2)
    return apps[0]["id"]


def client(repo):
    """(project dir, Client), or (dir, None) after printing what is missing."""
    repo = asc_check.project_dir(os.path.abspath(repo))  # HiveMind keeps its app in apps/ios
    text = open(os.path.join(repo, "Config", "Signing.xcconfig"), encoding="utf-8").read()
    key_id, issuer = asc_check.setting(text, "ASC_KEY_ID"), asc_check.setting(text, "ASC_ISSUER_ID")
    key_file = os.path.expanduser("~/.appstoreconnect/private_keys/AuthKey_%s.p8" % key_id)
    if not (key_id and issuer and (os.path.exists(key_file) or os.environ.get("HIVE_ASC_FAKE"))):
        print("asc_public_link: set ASC_KEY_ID and ASC_ISSUER_ID in Config/Signing.xcconfig")
        return repo, None
    return repo, asc_check.Client(key_id, issuer, key_file)


def status(repo, group):
    """Read-only: the newest processed build's beta review state and the group's public link, as one JSON line."""
    repo, c = client(repo)
    if c is None:
        return 2
    st = Steps(c, True)
    bundle = asc_check.bundle_id(repo)
    app = app_id(st, bundle)
    g = [g for g in st.get("/v1/apps/%s/betaGroups" % app) if g["attributes"].get("name") == group]
    link = g[0]["attributes"].get("publicLink") if g and g[0]["attributes"].get("publicLinkEnabled") else None
    builds = [b for b in st.get("/v1/builds?filter[app]=%s&sort=-uploadedDate&limit=5" % app)
              if b["attributes"].get("processingState") == "VALID"]
    out = {"bundle": bundle, "build": None, "state": "NO_BUILD", "public_link": link}
    if builds:
        b = builds[0]
        s, data = c.call("GET", "/v1/builds/%s/betaAppReviewSubmission" % b["id"])
        review = (data or {}).get("data") if s == 200 else None
        out["build"] = b["attributes"].get("version")
        out["state"] = (review or {}).get("attributes", {}).get("betaReviewState") or "NOT_SUBMITTED"
    print(json.dumps(out))
    return 0


def run(repo, group, description, contact_from, dry):
    repo, c = client(repo)
    if c is None:
        return 2
    st = Steps(c, dry)
    app, src = app_id(st, asc_check.bundle_id(repo)), app_id(st, contact_from)

    # 1. Review contact and feedback email, copied only where missing.
    detail = st.get("/v1/apps/%s/betaAppReviewDetail" % app)
    if not detail["attributes"].get("contactEmail"):
        have = st.get("/v1/apps/%s/betaAppReviewDetail" % src)["attributes"]
        if not have.get("contactEmail"):
            print("asc_public_link: %s has no review contact to copy" % contact_from)
            return 2
        st.write("PATCH", "/v1/betaAppReviewDetails/%s" % detail["id"],
                 {"data": {"type": "betaAppReviewDetails", "id": detail["id"],
                           "attributes": {k: have[k] for k in CONTACT}}}, "copy the review contact from " + contact_from)
    loc = st.get("/v1/apps/%s/betaAppLocalizations" % app)
    mine = next((x for x in loc if x["attributes"].get("locale") == "en-US"), loc[0] if loc else None)
    have = (mine or {}).get("attributes", {})
    if not (have.get("description") and have.get("feedbackEmail")):
        theirs = st.get("/v1/apps/%s/betaAppLocalizations" % src)
        email = have.get("feedbackEmail") or (theirs[0]["attributes"].get("feedbackEmail") if theirs else None)
        if not email:
            print("asc_public_link: no feedback email to copy from %s" % contact_from)
            return 2
        fields = {"description": have.get("description") or description, "feedbackEmail": email}
        if mine:
            st.write("PATCH", "/v1/betaAppLocalizations/%s" % mine["id"],
                     {"data": {"type": "betaAppLocalizations", "id": mine["id"], "attributes": fields}},
                     "fill the beta description and feedback email")
        else:
            st.write("POST", "/v1/betaAppLocalizations",
                     {"data": {"type": "betaAppLocalizations", "attributes": dict(locale="en-US", **fields),
                               "relationships": {"app": {"data": {"type": "apps", "id": app}}}}},
                     "add the beta description and feedback email")

    # 2. The external group with a public link.
    groups = [g for g in st.get("/v1/apps/%s/betaGroups" % app) if g["attributes"].get("name") == group]
    if groups:
        g = groups[0]
        if not g["attributes"].get("publicLinkEnabled"):
            g = st.write("PATCH", "/v1/betaGroups/%s" % g["id"],
                         {"data": {"type": "betaGroups", "id": g["id"], "attributes": {"publicLinkEnabled": True}}},
                         "turn on the public link of " + group) or g
    else:
        g = st.write("POST", "/v1/betaGroups",
                     {"data": {"type": "betaGroups",
                               "attributes": {"name": group, "publicLinkEnabled": True, "publicLinkLimitEnabled": False},
                               "relationships": {"app": {"data": {"type": "apps", "id": app}}}}},
                     "make the external group " + group)

    # 3. The newest processed build goes to the group and to beta review.
    builds = [b for b in st.get("/v1/builds?filter[app]=%s&sort=-uploadedDate&limit=5" % app)
              if b["attributes"].get("processingState") == "VALID"]
    if not builds:
        print("asc_public_link: no processed build yet; run again once Apple finishes processing")
        return 1
    b = builds[0]
    st.write("POST", "/v1/betaGroups/%s/relationships/builds" % g["id"],
             {"data": [{"type": "builds", "id": b["id"]}]}, "add build %s to %s" % (b["attributes"]["version"], group))
    status, data = st.c.call("GET", "/v1/builds/%s/betaAppReviewSubmission" % b["id"])
    review = (data or {}).get("data") if status == 200 else None  # 404: never submitted
    state = (review or {}).get("attributes", {}).get("betaReviewState")
    if state == "REJECTED":
        print("asc_public_link: Apple REJECTED build %s in beta review; read the reason in App Store Connect > "
              "TestFlight, fix it and upload a new build" % b["attributes"]["version"])
        return 1
    if state:
        print("beta review: %s (already submitted)" % state)
    else:
        st.write("POST", "/v1/betaAppReviewSubmissions",
                 {"data": {"type": "betaAppReviewSubmissions",
                           "relationships": {"build": {"data": {"type": "builds", "id": b["id"]}}}}},
                 "submit build %s to beta review" % b["attributes"]["version"])
    print("public link: %s" % (g.get("attributes", {}).get("publicLink") or "(shown once the group exists)"))
    return 0


def main(argv):
    args = argv[1:]
    if "--status" in args:
        try:
            return status(args[0], args[args.index("--group") + 1])
        except (IndexError, ValueError):
            print(__doc__.strip().splitlines()[3].strip())
            return 2
    try:
        repo = args[0]
        opt = {args[i]: args[i + 1] for i in range(1, len(args) - 1) if args[i].startswith("--") and args[i] != "--dry-run"}
        group, desc, src = opt["--group"], opt["--description"], opt["--contact-from"]
    except (IndexError, KeyError):
        print(__doc__.strip().splitlines()[2])
        return 2
    return run(repo, group, desc, src, "--dry-run" in args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
