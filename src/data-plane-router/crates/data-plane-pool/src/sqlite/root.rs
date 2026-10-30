/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   root.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Mount DSN → file path, and the opt-in confinement of that file to
//! `<root>/<tenant>/<file>` (`DATA_PLANE_SQLITE_ROOT`, G2-S1b). Unset, no path is checked or changed and
//! the writer opens with the same flags as before.

use data_plane_core::DataPlaneResult;
use rusqlite::OpenFlags;
use std::ffi::OsString;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Component, Path, PathBuf};

use super::error::path_refused;

const ROOT_VAR: &str = "DATA_PLANE_SQLITE_ROOT";
const TENANT_ID_MAX: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum SqliteRoot {
    Unset,
    /// `given` is the spelling DSNs must use; `canonical` is what it resolves to.
    Confined {
        given: PathBuf,
        canonical: PathBuf,
    },
    /// Set but not an absolute existing directory: every file mount is
    /// refused rather than opened unconfined.
    Invalid,
}

impl SqliteRoot {
    /// Read once, when the adapter is built at boot.
    pub(super) fn from_env() -> Self {
        let root = Self::from_value(std::env::var_os(ROOT_VAR));
        if root == Self::Invalid {
            tracing::error!(
                "{ROOT_VAR} is set but is not an absolute existing directory; \
                 every sqlite file mount is refused"
            );
        }
        root
    }

    pub(super) fn from_value(value: Option<OsString>) -> Self {
        let Some(given) = value.map(PathBuf::from) else {
            return Self::Unset;
        };
        if !given.is_absolute() {
            return Self::Invalid;
        }
        match given.canonicalize() {
            Ok(canonical) if canonical.is_dir() => Self::Confined { given, canonical },
            _ => Self::Invalid,
        }
    }

    pub(super) fn writer_flags(&self) -> OpenFlags {
        match self {
            Self::Unset => OpenFlags::default(),
            _ => OpenFlags::default() | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        }
    }

    /// Accepts `path` only as a direct child of `<root>/<tenant_id>/`, creating
    /// that directory 0700 (one level, never the root) on first use. `:memory:`
    /// touches no file and always passes.
    ///
    /// Caveat: check-then-open. A process that can write inside the tenant
    /// directory can swap in a symlink after this check; the writer's
    /// `SQLITE_OPEN_NOFOLLOW` still refuses it, the reader pool does not
    /// (deadpool-sqlite opens with no flags). A hard link, and the `-wal` /
    /// `-shm` sidecars, are not checked at all.
    pub(super) fn confine(&self, path: &str, tenant_id: &str) -> DataPlaneResult<()> {
        let (given, canonical) = match self {
            Self::Unset => return Ok(()),
            _ if path == ":memory:" => return Ok(()),
            Self::Invalid => return Err(path_refused("the sqlite root is misconfigured")),
            Self::Confined { given, canonical } => (given, canonical),
        };
        if !is_safe_segment(tenant_id) {
            return Err(path_refused(
                "a tenant id that is not one safe path segment",
            ));
        }
        let file = Path::new(path);
        let tenant_dir = given.join(tenant_id);
        let plain = file.is_absolute()
            && file
                .components()
                .all(|c| matches!(c, Component::RootDir | Component::Normal(_)));
        if !plain || file.parent() != Some(tenant_dir.as_path()) {
            return Err(path_refused("a path outside <root>/<tenant>/"));
        }
        if let Err(e) = std::fs::DirBuilder::new().mode(0o700).create(&tenant_dir) {
            if e.kind() != std::io::ErrorKind::AlreadyExists {
                return Err(path_refused("a tenant directory that cannot be created"));
            }
        }
        if tenant_dir.canonicalize().ok() != Some(canonical.join(tenant_id)) {
            return Err(path_refused(
                "a tenant directory that resolves outside the root",
            ));
        }
        if std::fs::symlink_metadata(file).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(path_refused("a symlinked database file"));
        }
        Ok(())
    }
}

/// Parse a `sqlite:` DSN to a file path (or `:memory:`).
pub(super) fn sqlite_path(dsn: &str) -> String {
    let s = dsn
        .strip_prefix("sqlite://")
        .or_else(|| dsn.strip_prefix("sqlite:"))
        .unwrap_or(dsn);
    if s.is_empty() || s == ":memory:" {
        ":memory:".to_string()
    } else {
        s.to_string()
    }
}

fn is_safe_segment(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= TENANT_ID_MAX
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

#[cfg(test)]
mod tests {
    use super::super::writer::open_writer_conn;
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("g2-root-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn confined(dir: &Path) -> SqliteRoot {
        SqliteRoot::from_value(Some(dir.into()))
    }

    fn at(dir: &Path, rest: &str) -> String {
        format!("{}/{rest}", dir.display())
    }

    #[test]
    fn dsn_parsing() {
        for (dsn, path) in [
            ("sqlite:///var/lib/x.db", "/var/lib/x.db"),
            ("sqlite::memory:", ":memory:"),
            ("sqlite://", ":memory:"),
            ("/abs/path.db", "/abs/path.db"),
            ("sqlite:", ":memory:"),
            ("sqlite://relative/db.sqlite", "relative/db.sqlite"),
            ("", ":memory:"),
            (":memory:", ":memory:"),
            ("sqlite:///tmp/a b.db", "/tmp/a b.db"),
        ] {
            assert_eq!(sqlite_path(dsn), path, "{dsn}");
        }
    }

    #[test]
    fn unset_checks_nothing_and_keeps_the_default_flags() {
        let root = SqliteRoot::from_value(None);
        assert_eq!(root, SqliteRoot::Unset);
        for path in ["/tmp/x.db", "relative/x.db", "/a/../b.db", ":memory:", ""] {
            for tenant in ["t", "", "../x"] {
                assert!(root.confine(path, tenant).is_ok(), "{path} {tenant}");
            }
        }
        assert_eq!(root.writer_flags(), OpenFlags::default());
    }

    #[test]
    fn a_root_that_is_not_an_absolute_existing_directory_is_invalid() {
        let dir = scratch("invalid");
        std::fs::write(dir.join("file"), b"").unwrap();
        for value in ["", "relative", "/nonexistent-g2-root"] {
            assert_eq!(confined(Path::new(value)), SqliteRoot::Invalid, "{value}");
        }
        assert_eq!(confined(&dir.join("file")), SqliteRoot::Invalid);
        let invalid = SqliteRoot::Invalid;
        assert!(invalid.confine(&at(&dir, "t/m.db"), "t").is_err());
        assert!(invalid.confine(":memory:", "t").is_ok());
        assert!(invalid
            .writer_flags()
            .contains(OpenFlags::SQLITE_OPEN_NOFOLLOW));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_confined_path_creates_its_tenant_directory_0700() {
        let dir = scratch("ok");
        let root = confined(&dir);
        root.confine(&at(&dir, "t-1_A/m.db"), "t-1_A").unwrap();
        let mode = std::fs::metadata(dir.join("t-1_A"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o700);
        root.confine(&at(&dir, "t-1_A/other.db"), "t-1_A").unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn paths_and_tenant_ids_outside_the_shape_are_refused_before_any_mkdir() {
        let dir = scratch("refused");
        let root = confined(&dir);
        for path in [
            at(&dir, "t/../u/m.db"),
            at(&dir, "u/m.db"),
            at(&dir, "t/sub/m.db"),
            at(&dir, "m.db"),
            "t/m.db".to_string(),
            "/tmp/t/m.db".to_string(),
        ] {
            assert!(root.confine(&path, "t").is_err(), "{path}");
        }
        let long = "a".repeat(TENANT_ID_MAX + 1);
        for tenant in ["", ".", "..", "a/b", "a.b", "a b", long.as_str()] {
            assert!(
                root.confine(&at(&dir, &format!("{tenant}/m.db")), tenant)
                    .is_err(),
                "{tenant}"
            );
        }
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn symlinks_out_of_the_root_are_refused() {
        let dir = scratch("links");
        let outside = scratch("links-outside");
        let base = dir.join("root");
        std::fs::create_dir(&base).unwrap();
        let root = confined(&base);
        symlink(&outside, base.join("t")).unwrap();
        assert!(root.confine(&at(&base, "t/m.db"), "t").is_err());
        std::fs::create_dir(base.join("u")).unwrap();
        std::fs::write(outside.join("victim.db"), b"").unwrap();
        symlink(outside.join("victim.db"), base.join("u/m.db")).unwrap();
        assert!(root.confine(&at(&base, "u/m.db"), "u").is_err());
        let flags = root.writer_flags();
        assert!(open_writer_conn(&at(&base, "u/m.db"), flags).is_err());
        assert!(open_writer_conn(&at(&base, "u/plain.db"), flags).is_ok());
        let _ = std::fs::remove_dir_all(dir);
        let _ = std::fs::remove_dir_all(outside);
    }
}
