//! The deployment's identity (`GROBASE_ENV`) and the error a config load can raise.
//!
//! The identity decides how strictly a missing secret is treated: a refusal to
//! boot in staging and prod, tolerated in local and dev. Errors name KEYS only —
//! never a configured value.

use std::fmt;

/// Env var that states which deployment this is
/// (`infra/config/env/schema.json`, category ENVIRONMENT). Unset or empty = local.
pub const ENVIRONMENT_KEY: &str = "GROBASE_ENV";

/// Which deployment this process belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Environment {
    Local,
    Dev,
    Staging,
    Prod,
}

impl Environment {
    /// Parse a raw `GROBASE_ENV` value. Empty (after trimming) means `Local`; the
    /// match is exact and lower-case like the schema enum, so a typo such as
    /// `"Prod"` fails closed instead of silently becoming `Local`.
    ///
    /// # Errors
    /// `ConfigError::UnknownEnvironment` for any other value.
    pub fn parse(raw: &str) -> Result<Self, ConfigError> {
        match raw.trim() {
            "" | "local" => Ok(Self::Local),
            "dev" => Ok(Self::Dev),
            "staging" => Ok(Self::Staging),
            "prod" => Ok(Self::Prod),
            _ => Err(ConfigError::UnknownEnvironment),
        }
    }

    /// The schema spelling of this environment.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Dev => "dev",
            Self::Staging => "staging",
            Self::Prod => "prod",
        }
    }

    /// Whether a missing required secret must stop the process (staging, prod).
    #[must_use]
    pub fn is_strict(self) -> bool {
        matches!(self, Self::Staging | Self::Prod)
    }
}

/// Why a configuration load was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    /// `GROBASE_ENV` is set to a value outside the allowed set. The offending
    /// value is deliberately not carried, so it cannot be printed.
    UnknownEnvironment,
    /// `DATA_PLANE_INBOUND_AUTH` is not `off`, `shadow` or `enforce`. Refused
    /// rather than read as `off`, so a typo cannot silently disable the check.
    UnknownInboundAuthMode,
    /// `DATA_PLANE_DIAL_GUARD` is not `off`, `shadow` or `enforce`. Refused for
    /// the same reason: a typo must not leave tenant dials unguarded.
    UnknownDialGuardMode,
    /// `DATA_PLANE_CALLER_POLICY` is not `off`, `shadow` or `enforce` (D1).
    UnknownCallerPolicyMode,
    /// A caller key fails the startup check while the caller policy is on
    /// (D1, ADR 0023). `key` and `problem` are static, so no value is carried.
    CallerKey {
        key: &'static str,
        problem: CallerKeyProblem,
    },
    /// Required secrets are unset or empty in a strict environment. `keys` is
    /// `&'static str`, so only key names can ever appear here — never a value.
    MissingSecrets {
        environment: Environment,
        keys: Vec<&'static str>,
    },
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownEnvironment => write!(
                f,
                "{ENVIRONMENT_KEY} is not a known environment (allowed: local, dev, staging, prod)"
            ),
            Self::UnknownInboundAuthMode => write!(
                f,
                "DATA_PLANE_INBOUND_AUTH is not a known mode (allowed: off, shadow, enforce)"
            ),
            Self::UnknownDialGuardMode => write!(
                f,
                "DATA_PLANE_DIAL_GUARD is not a known mode (allowed: off, shadow, enforce)"
            ),
            Self::UnknownCallerPolicyMode => write!(
                f,
                "DATA_PLANE_CALLER_POLICY is not a known mode (allowed: off, shadow, enforce)"
            ),
            Self::CallerKey { key, problem } => write!(
                f,
                "{key} {} (DATA_PLANE_CALLER_POLICY is shadow or enforce)",
                problem.describe()
            ),
            Self::MissingSecrets { environment, keys } => write!(
                f,
                "missing required configuration: {} ({ENVIRONMENT_KEY}={})",
                keys.join(", "),
                environment.as_str()
            ),
        }
    }
}

impl std::error::Error for ConfigError {}

/// Why a caller key was refused at startup.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallerKeyProblem {
    Unset,
    TooShort,
    /// Equal to the named variable's value, so the two callers share a class.
    SameAs(&'static str),
}

impl CallerKeyProblem {
    fn describe(self) -> String {
        match self {
            Self::Unset => "is unset or empty".to_string(),
            Self::TooShort => "is shorter than 32 bytes".to_string(),
            Self::SameAs(other) => format!("equals {other}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_accepts_the_schema_values_and_defaults_to_local() {
        let cases = [
            ("", Environment::Local),
            ("   ", Environment::Local),
            ("local", Environment::Local),
            ("dev", Environment::Dev),
            ("staging", Environment::Staging),
            ("prod", Environment::Prod),
            (" prod\n", Environment::Prod),
        ];
        for (raw, want) in cases {
            assert_eq!(Environment::parse(raw), Ok(want), "raw={raw:?}");
        }
    }

    #[test]
    fn parse_rejects_everything_else_and_fails_closed_on_case() {
        for raw in ["production", "PROD", "Prod", "stage", "development", "x"] {
            assert_eq!(
                Environment::parse(raw),
                Err(ConfigError::UnknownEnvironment),
                "raw={raw:?}"
            );
        }
    }

    #[test]
    fn only_staging_and_prod_are_strict() {
        assert!(!Environment::Local.is_strict());
        assert!(!Environment::Dev.is_strict());
        assert!(Environment::Staging.is_strict());
        assert!(Environment::Prod.is_strict());
    }

    #[test]
    fn as_str_round_trips_through_parse() {
        for env in [
            Environment::Local,
            Environment::Dev,
            Environment::Staging,
            Environment::Prod,
        ] {
            assert_eq!(Environment::parse(env.as_str()), Ok(env));
        }
    }

    #[test]
    fn unknown_environment_message_names_the_set_not_the_value() {
        let msg = ConfigError::UnknownEnvironment.to_string();
        for allowed in ["local", "dev", "staging", "prod"] {
            assert!(msg.contains(allowed), "{msg} does not name {allowed}");
        }
        assert!(msg.contains(ENVIRONMENT_KEY));
    }

    #[test]
    fn missing_secrets_message_lists_every_key_and_the_environment() {
        let msg = ConfigError::MissingSecrets {
            environment: Environment::Prod,
            keys: vec!["INTERNAL_SERVICE_TOKEN", "DATA_PLANE_VAULT_TOKEN"],
        }
        .to_string();
        assert_eq!(
            msg,
            "missing required configuration: INTERNAL_SERVICE_TOKEN, DATA_PLANE_VAULT_TOKEN (GROBASE_ENV=prod)"
        );
    }
}
