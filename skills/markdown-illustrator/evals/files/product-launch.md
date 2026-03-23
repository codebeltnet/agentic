# Product Launch Playbook

## Vision and Strategy

We are building a developer-first API platform that makes it trivial to add authentication to any application. The market is crowded (Auth0, Clerk, Firebase Auth) but fragmented — no single solution handles mobile, web, and server-to-server auth well across all frameworks.

Our bet: a unified SDK that works identically in React, Swift, Kotlin, and server-side Node/Python/Go. One API surface, one dashboard, one billing model.

## Target Personas

### Indie Developer (Solo)
Ships side projects on weekends. Needs auth that "just works" in 5 minutes. Price-sensitive — free tier is critical. Values clear docs over feature depth.

### Startup CTO (Team of 5-15)
Scaling fast. Needs SSO, RBAC, and audit logs yesterday. Will pay $500-2000/month for reliability and compliance (SOC2, HIPAA). Cares about uptime SLA.

### Enterprise Architect
Evaluates over 6-month cycles. Needs SAML, SCIM, custom domains, data residency. Budget is not the constraint — security review and vendor risk assessment are.

## Go-to-Market Phases

**Phase 1 (Months 1-3)**: Developer preview. Ship core auth (email/password, OAuth, magic link). Free tier only. Goal: 500 developers, 10 production apps.

**Phase 2 (Months 4-6)**: Paid launch. Add SSO, RBAC, webhooks. Launch Pro tier at $29/month. Goal: 50 paying customers.

**Phase 3 (Months 7-12)**: Enterprise. SAML, SCIM, SLA, dedicated support. Custom pricing. Goal: 5 enterprise contracts.

## What This Is NOT

- Not a full identity platform (no KYC, no identity verification)
- Not a user management system (no CRM, no marketing automation)
- Not a security product (no WAF, no DDoS protection)

We do one thing — authentication — and we do it exceptionally well.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Auth0 drops pricing | High | Differentiate on DX, not price |
| Security breach | Critical | Bug bounty program, pen testing, SOC2 from day 1 |
| Slow enterprise sales | Medium | Focus on PLG (product-led growth) for steady revenue |
| SDK maintenance burden | Medium | Code generation from OpenAPI spec |
