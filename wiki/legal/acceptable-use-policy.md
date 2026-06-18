# Acceptable Use Policy (AUP)

> **TEMPLATE — review by counsel before use; not legal advice.** Scaffold for the
> Grobase managed-cloud offering. Not lawyer-reviewed. Adjust the prohibited-use list
> and enforcement to your jurisdiction and risk posture.

This Acceptable Use Policy governs use of the Grobase managed Service and is part of
the [Terms of Service](./terms-of-service.md). It applies to you and anyone using the
Service through your account.

## 1. Prohibited uses

You may not use the Service to:

- violate any law or third-party right (IP, privacy, contract);
- send spam or unsolicited bulk messaging, or facilitate phishing/fraud;
- store or distribute malware, or use the Service to attack other systems;
- attempt to breach isolation, access another tenant's data, or probe/penetrate the
  Service without written authorization (see §3, responsible disclosure);
- host content that is illegal, that infringes others, or that the provider is legally
  required to remove;
- circumvent usage metering, quotas, or rate limits, or resell capacity in violation
  of the Terms.

## 2. Fair use, quotas, and abuse controls

- Each plan has measured rps/burst limits and usage quotas. Exceeding a quota may
  return HTTP 402 (when quota enforcement is enabled) or be rate-limited.
- The Service runs abuse-guard and per-tenant IP-allowlist controls (see the
  [trust center](../security/trust-center.md), control `network-access-control`, gate m106).
- Sustained abusive load that degrades the Service for others may be throttled or
  suspended.

## 3. Security research / responsible disclosure

We welcome good-faith security research. Report vulnerabilities to
`[security@EXAMPLE.com]` per our disclosure policy (trust center control
`vulnerability-disclosure`). Do not access other tenants' data, run denial-of-service
tests, or exfiltrate data while testing.

## 4. Enforcement

We may remove content, throttle, suspend, or terminate access for AUP violations,
with notice where practicable and immediately where required to protect the Service,
other customers, or third parties.

## 5. Reporting

Report abuse to `[abuse@EXAMPLE.com]`.
