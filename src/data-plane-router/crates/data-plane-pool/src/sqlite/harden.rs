/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   harden.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 14:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 14:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! What every pool SQLite connection is allowed to reach (G2-S1, ADR 0015).
//!
//! Raw SQL on a mount (`/v1/admin/raw`) used to run with no authorizer and no
//! limits: `ATTACH '/tmp/<other>.db'` or `VACUUM INTO` read or wrote any file
//! the process could, and a `file:...?vfs=` DSN chose the VFS. This is
//! HARDENING of one connection, not tenant isolation: a body-supplied
//! `inline_dsn` can still name another tenant's file until the root
//! confinement and G1 land (ADR 0015 lists what stays open).
//!
//! Plain `VACUUM` is refused too: SQLite runs it as `ATTACH ... AS vacuum_db`
//! (sqlite3.c `sqlite3RunVacuum`), which both the limit and the authorizer stop.

use data_plane_core::DataPlaneResult;
use rusqlite::config::DbConfig;
use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use rusqlite::limits::Limit;
use rusqlite::Connection;
use std::path::Path;

use super::error::path_refused;

/// Pragmas whose WRITE either changes the whole process (`*_directory`,
/// `*_heap_limit`), switches a guard below off (`writable_schema`,
/// `trusted_schema`), or breaks the WAL + single-writer design
/// (`journal_mode`, `locking_mode`). Reading any of them stays allowed. The
/// table-valued `pragma_<name>()` form cannot write them: only pragmas flagged
/// `PragFlg_Result1` get an argument column (sqlite3.c `pragmaVtabConnect`).
const GUARDED_PRAGMAS: &[&str] = &[
    "temp_store_directory",
    "data_store_directory",
    "soft_heap_limit",
    "hard_heap_limit",
    "writable_schema",
    "trusted_schema",
    "journal_mode",
    "locking_mode",
];

/// The server's own SQLite files under `NANO_DATA_DIR` (nano.rs, one.rs,
/// pb/mod.rs): keys, users, PocketBase metadata and logs. `main.db` is absent
/// on purpose: it is the nano default mount and opens through this adapter.
const SERVER_FILES: &[&str] = &["nano_meta.db", "pb_meta.db", "pb_logs.db"];
const SIDECARS: &[&str] = &["", "-wal", "-shm", "-journal"];

/// The adapter's own pragmas. They run BEFORE [`harden`], whose authorizer
/// would refuse the `journal_mode` write. On an existing WAL file the
/// `journal_mode` write is a no-op; [`super::writer::enable_wal`] makes it so.
pub(super) fn tune(conn: &Connection) -> rusqlite::Result<()> {
    conn.pragma_update(None, "journal_mode", "WAL")?;
    // The standard WAL pairing (and what PocketBase ships): NORMAL skips the
    // per-commit fsync that FULL forces — the database can never corrupt, at
    // worst the last commits roll back on an OS crash. Default FULL made every
    // insert pay a ~10 ms fsync, 2-3x slower than PocketBase on the same disk.
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "busy_timeout", 5000)?;
    conn.pragma_update(None, "foreign_keys", "ON")
}

/// Locks one connection down: defensive mode, untrusted schema, zero attached
/// databases, and the authorizer. Call it once, right after open, on EVERY
/// connection (deadpool `post_create`, the writer thread). The nano/pb stores
/// are one call away from the same protection.
pub fn harden(conn: &Connection) -> rusqlite::Result<()> {
    lock_config(conn)?;
    conn.authorizer(Some(authorize));
    Ok(())
}

fn lock_config(conn: &Connection) -> rusqlite::Result<()> {
    conn.set_db_config(DbConfig::SQLITE_DBCONFIG_DEFENSIVE, true)?;
    conn.set_db_config(DbConfig::SQLITE_DBCONFIG_TRUSTED_SCHEMA, false)?;
    conn.set_limit(Limit::SQLITE_LIMIT_ATTACHED, 0);
    Ok(())
}

fn authorize(ctx: AuthContext<'_>) -> Authorization {
    let denied = match ctx.action {
        AuthAction::Attach { .. } | AuthAction::Detach { .. } => true,
        AuthAction::Function { function_name } => {
            function_name.eq_ignore_ascii_case("load_extension")
        }
        AuthAction::Pragma {
            pragma_name,
            pragma_value: Some(_),
        } => GUARDED_PRAGMAS
            .iter()
            .any(|guarded| pragma_name.eq_ignore_ascii_case(guarded)),
        _ => false,
    };
    if denied {
        Authorization::Deny
    } else {
        Authorization::Allow
    }
}

/// Refuses a mount path before any connection or writer thread exists. The
/// error names the path's SHAPE, never its value (it may carry a secret).
///
/// Caveat: the server-file check matches the file NAME. A symlink or hard
/// link to `nano_meta.db` under another name passes. The opt-in
/// `DATA_PLANE_SQLITE_ROOT` confinement ([`super::root`]) refuses the symlink,
/// not the hard link.
pub(super) fn refuse_unsafe_path(path: &str) -> DataPlaneResult<()> {
    let refuse = |shape: &str| Err(path_refused(shape));
    // SQLite is built with SQLITE_USE_URI, so `file:` picks the VFS and
    // the open mode whatever flags the caller passes.
    if path.starts_with("file:") {
        return refuse("a file: URI");
    }
    if path.contains('?') {
        return refuse("a path holding '?'");
    }
    let name = Path::new(path).file_name().and_then(|n| n.to_str());
    let is_server_file = name.is_some_and(|name| {
        SERVER_FILES.iter().any(|file| {
            SIDECARS
                .iter()
                .any(|suffix| name.strip_suffix(suffix) == Some(file))
        })
    });
    if is_server_file {
        return refuse("one of the server's own metadata files");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::exec::{exec_write, query_rows};
    use super::{authorize, harden, lock_config, refuse_unsafe_path, tune};
    use super::{GUARDED_PRAGMAS, SERVER_FILES};
    use rusqlite::types::Value as SqlValue;
    use rusqlite::Connection;
    use std::path::PathBuf;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("g2-harden-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn open(dir: &std::path::Path, setup: fn(&Connection)) -> Connection {
        let conn = Connection::open(dir.join("mount.db")).unwrap();
        tune(&conn).unwrap();
        setup(&conn);
        conn
    }

    /// Refused on the read path (`expect_rows=true`) AND the write path, for
    /// the reason `why` — so a statement failing for some other reason
    /// cannot pass for a guard.
    fn assert_refused(conn: &Connection, sql: &str, why: &str) {
        let read = query_rows(conn, sql, &[]).map(|_| ());
        let write = exec_write(conn, sql, &[]).map(|_| ());
        for (path, result) in [("read", read), ("write", write)] {
            let err = result.expect_err(sql).to_string();
            assert!(err.contains(why), "{path} path, {sql}: {err}");
        }
    }

    #[test]
    fn unsafe_paths_are_refused_by_shape() {
        let refused = [
            "file:/tmp/x.db?vfs=memdb",
            "file:x",
            "/tmp/a?b.db",
            "/srv/nano_data/nano_meta.db",
            "nano_data/pb_meta.db-wal",
            "pb_logs.db-journal",
            "./nano_data/./pb_meta.db-shm",
        ];
        for path in refused {
            let err = refuse_unsafe_path(path).expect_err(path).to_string();
            assert!(!err.contains(path), "the error echoes the path: {err}");
        }
        for path in [
            ":memory:",
            "/var/lib/x.db",
            "/tmp/a b.db",
            "relative/db.sqlite",
            "/srv/nano_data/main.db",
            "/srv/nano_meta.db.bak",
            "/srv/my_nano_meta.db",
        ] {
            refuse_unsafe_path(path).expect(path);
        }
        assert_eq!(SERVER_FILES.len(), 3);
    }

    /// S5: each guard alone refuses ATTACH, DETACH, VACUUM INTO and VACUUM,
    /// and an unguarded connection runs all four (the test is not vacuous).
    #[test]
    fn attach_and_vacuum_are_refused_by_the_limit_and_by_the_authorizer_alone() {
        let dir = scratch("attach");
        let other = dir.join("other.db");
        let into = dir.join("into.db");
        let attach = format!("ATTACH '{}' AS other", other.display());
        let vacuum_into = format!("VACUUM INTO '{}'", into.display());

        let open_conn = open(&dir, |_| {});
        exec_write(&open_conn, &attach, &[]).unwrap();
        exec_write(&open_conn, "DETACH other", &[]).unwrap();
        exec_write(&open_conn, &vacuum_into, &[]).unwrap();
        exec_write(&open_conn, "VACUUM", &[]).unwrap();
        assert!(into.exists());
        std::fs::remove_file(&into).unwrap();
        std::fs::remove_file(&other).unwrap();

        let limited = open(&dir, |c| lock_config(c).unwrap());
        assert_refused(&limited, &attach, "too many attached databases");
        assert_refused(&limited, &vacuum_into, "too many attached databases");
        assert_refused(&limited, "VACUUM", "too many attached databases");
        // Nothing can be attached, so there is nothing to detach.
        assert_refused(&limited, "DETACH other", "no such database");

        let authorized = open(&dir, |_| {});
        exec_write(&authorized, &attach, &[]).unwrap();
        authorized.authorizer(Some(authorize));
        for sql in [attach.as_str(), "DETACH other", &vacuum_into, "VACUUM"] {
            // "not authorized" when the statement itself is denied,
            // "authorization denied" when VACUUM's inner ATTACH is.
            assert_refused(&authorized, sql, "authoriz");
        }
        assert!(!into.exists(), "a guard let VACUUM INTO write its target");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_guarded_pragma_write_is_refused_and_its_read_is_not() {
        let dir = scratch("pragma");
        let conn = open(&dir, |c| harden(c).unwrap());
        conn.execute_batch("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
            .unwrap();
        for pragma in GUARDED_PRAGMAS {
            for spelled in [pragma.to_string(), pragma.to_ascii_uppercase()] {
                let err = query_rows(&conn, &format!("PRAGMA {spelled} = 1"), &[])
                    .expect_err(&spelled)
                    .to_string();
                assert!(err.contains("not authorized"), "{spelled}: {err}");
            }
            query_rows(&conn, &format!("PRAGMA {pragma}"), &[]).expect(pragma);
        }
        let mode: String = conn
            .query_row("PRAGMA journal_mode", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mode, "wal");
        assert_eq!(
            query_rows(&conn, "PRAGMA table_info(t)", &[])
                .unwrap()
                .len(),
            2
        );
        query_rows(
            &conn,
            "SELECT * FROM pragma_foreign_key_list(?1)",
            &[SqlValue::Text("t".into())],
        )
        .unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn load_extension_and_a_schema_rewrite_are_refused() {
        let dir = scratch("defensive");
        let conn = open(&dir, |c| harden(c).unwrap());
        let err = query_rows(&conn, "SELECT load_extension('/nonexistent')", &[])
            .expect_err("load_extension ran")
            .to_string();
        assert!(err.contains("not authorized"), "{err}");
        conn.execute_batch("CREATE TABLE t (id INTEGER)").unwrap();
        let rewrite = "UPDATE sqlite_master SET sql = 'CREATE TABLE t (x)' WHERE name = 't'";
        assert!(exec_write(&conn, "PRAGMA writable_schema=ON", &[]).is_err());
        assert!(exec_write(&conn, rewrite, &[]).is_err());

        // DEFENSIVE holds on its own, with the pragma let through.
        let defensive = Connection::open(dir.join("mount.db")).unwrap();
        lock_config(&defensive).unwrap();
        exec_write(&defensive, "PRAGMA writable_schema=ON", &[]).unwrap();
        assert!(
            exec_write(&defensive, rewrite, &[]).is_err(),
            "defensive mode let the schema be rewritten"
        );
        let _ = std::fs::remove_dir_all(dir);
    }
}
