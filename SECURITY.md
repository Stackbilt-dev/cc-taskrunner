# Security

For the full Stackbilt security policy, see https://docs.stackbilt.dev/security/.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

### How to report

- **Primary channel:** email `admin@stackbilt.dev` with "SECURITY:" in the subject line
- **GitHub Security Advisory:** https://github.com/Stackbilt-dev/cc-taskrunner/security/advisories/new
- Include: vulnerability description, reproduction steps, potential impact, and any suggested mitigation

### Response targets

| Severity | Acknowledgement | Fix target |
|---|---|---|
| Critical — active exploitation, data exposure | 24 hours | 7 days |
| High — exploitable with effort | 48 hours | 14 days |
| Medium / Low | 5 business days | Next release cycle |

These are targets, not contractual SLAs. Stackbilt is a solo-founder operation and response times reflect that reality honestly. Critical issues affecting user data are prioritized above everything else.

### Scope

This policy covers all software published in this repository. For the full policy covering the entire Stackbilt-dev organization, see the [canonical security policy](https://docs.stackbilt.dev/security/).

### Out of scope

- Denial of service against free-tier services (Cloudflare handles DDoS)
- Rate limiting bypass on non-authenticated endpoints (unless it enables data access)
- Missing security headers on non-production deployments
- Vulnerabilities in third-party dependencies where this repo is not the upstream maintainer

### Disclosure

- Stackbilt practices **coordinated disclosure** with a minimum 90-day window (30 days for critical).
- Reporters are credited in release notes unless anonymity is requested.
- Good-faith security research within this policy will not face legal action.

### Contact

- **Primary:** admin@stackbilt.dev
- **Canonical policy:** https://docs.stackbilt.dev/security/
