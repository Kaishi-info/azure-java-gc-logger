# Public repository publication checklist

This is a source distribution intended for a public GitHub repository. It has not
been deployed to production or independently validated against live Azure Monitor.

## Before the first push

1. Confirm the publishing organization, repository administrators, and the
   right to publish this source code. The MIT LICENSE currently attributes
   copyright to AICU Inc.; hosting it in another organization does not by
   itself transfer copyright. Change attribution only with authorization.
2. Confirm the repository will be public and that no live customer telemetry,
   heap dump, Azure subscription ID, credentials, or private configuration is
   included in its first commit or history.
3. Run `sh tests/run_all.sh --docker` on a development workstation (add
   `--lms` for the LMS scenarios). Use a disposable, synthetic environment for
   any Azure ingestion tests.
4. Ensure an appropriate security contact and an owner for future maintenance.
5. Keep the first release marked **reference implementation / not validated
   in production**. Version v0.1.0 is suitable as a preview tag, not a claim
   of production readiness.

## Publish with the GitHub CLI (on an authorized workstation)

From the repository root:

```sh
git init -b main
git add .
git commit -m "Initial public reference implementation"
gh repo create YOUR_ORG/azure-java-gc-logger --public --source=. --remote=origin --push
```

Replace `YOUR_ORG` with the approved GitHub organization. This requires an
account with permission to create public repositories there. If the repository
already exists, instead configure the matching remote and push to it using
its established branch and review policy.

## First post-publication checks

- Confirm the `ci` workflow passes (lint, public-content check, unit tests on
  Linux and macOS, real-JVM job). Run `lms-scenario` once by hand.
- Releases: push a `vX.Y.Z` tag that matches `collect_gc.sh --version`; the
  `release` workflow publishes archives with SHA-256 sums.
- Open `dashboard/index.html#demo` on a workstation.
- Verify `AGENTS.md`, `README.ja.md`, and `azure/README.md` are rendered.
- Do not create public issues containing actual customer logs, heap dumps,
  student records, or service credentials.
