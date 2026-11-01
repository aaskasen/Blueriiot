# Premium features

The account's device reports `contract_servicePlan: "plus"`, `contract_isBasic: true`; the `blue` list reports `upgradedToPlusCount: 1`. The App Store description lists "a complete measurement history" as Premium.

| Capability | Observed | Gated by Premium? |
|---|---|---|
| Full history (`measures`, back to 2019) | Verified on this account | **Unknown.** No non-Premium account was available to compare. |
| Guidance / recommendations (`guidance`, `guidance/history`) | Verified | Unknown |
| Feed / alerts (`feed`) | Verified | Unknown |
| `userModuleAccess.va_config`, `autom_targets_config` | `true` | Probably module entitlements; meaning unconfirmed |

No request was rejected for entitlement reasons. Finding the exact gating would need a non-Premium account, which is out of scope (owner's account only).
