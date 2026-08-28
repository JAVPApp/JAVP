## Supported versions

Security fixes target the latest **stable** release on `main` and, when
practical, the current **dev** channel. Older tagged builds may not get
backports.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

Use [GitHub private vulnerability reporting](https://github.com/JAVPApp/JAVP/security/advisories/new)
on this repository, or contact maintainers via [javp.app](https://javp.app).

Include:

- A short description of the issue and impact
- Steps to reproduce (proof-of-concept only — no weaponized exploits)
- Affected platform(s) and app version / commit if known

We will acknowledge receipt and work on a fix. Please give a reasonable window
before any public disclosure.

## Scope notes

- Secrets for store publish, signing, and FTP live in CI secrets / local `.env`
  — never commit them.
- Bring-your-own media: the app does not host or distribute media content.
- Optional third-party APIs (TMDB, SIMKL, Cast, …) follow those providers’ terms.
