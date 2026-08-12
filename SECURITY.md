# Security

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's
private vulnerability-reporting feature if it is enabled for this repository;
otherwise contact the maintainer privately through the GitHub profile before
sharing exploit details or logs.

Do not attach an unredacted KOReader `crash.log`, settings file, Grimmory
database export, or real EPUB to a public issue.

## Deployment assumptions

This is a client for a personally administered Kindle and Grimmory server, not
a hardened multi-user endpoint. In particular:

- Prefer an HTTPS Grimmory URL. If HTTP is used on a LAN or tailnet, login
  credentials and tokens are not protected against another party able to
  observe that network traffic.
- KOReader plugin settings contain access and refresh tokens. They are stored
  on the Kindle using KOReader's normal settings mechanism, without additional
  encryption. Treat physical or shell access to the device as trusted.
- The updater obtains its generated manifest and required checksums from the
  latest published GitHub release over HTTPS. Checksums detect damaged or
  substituted archive bytes, but they are not an independent signature if the
  GitHub account or repository is compromised.
- Downloaded book files, annotations, reading sessions, and library metadata
  are private user data. Review logs and generated test reports before sharing
  them.

The public test suite exercises authentication renewal, request serialization,
archive paths and checksums, filename sanitization, offline queues, and conflict
handling. Passing those tests is not a claim that every deployment is secure.
