# Security Policy

This is a personal lab repository maintained by [@bookvt](https://github.com/bookvt). It has no SLA, but security reports are taken seriously.

## Reporting a vulnerability

**Please do not open a public issue.**

Report privately through GitHub: **Security → Report a vulnerability** ([private vulnerability reporting](https://github.com/bookvt/vaewprach-lab/security/advisories/new)).

Please include:

- What is affected (file, workflow, endpoint)
- Steps to reproduce or a proof of concept
- The impact you expect

## Leaked secrets

If you find a credential in this repository, its history, CI logs, or artifacts, report it the same way. Any leaked secret is **rotated first**, then removed from history.

## Scope

- This repository, its GitHub Actions workflows, and released container images
- Public endpoints under `*.vaewlab.duckdns.org`

Do not run denial-of-service tests or automated scans against the public endpoints.
