//! Schema-surface checks for [`crate::run_suite`]: structured DDL round-trip,
//! foreign-key introspection, and route honesty (a route capability the
//! descriptor marks false must refuse, never serve).

use data_plane_core::{
    DataPlaneError, DdlColumnDef, EngineCapabilities, EnginePool, MigrationRequest, NormalizedType,
    RequestIdentity, SchemaDdlOp, SchemaDdlRequest, SchemaDescriptor, TxBeginRequest,
};

use crate::raw;

const DDL_TABLE: &str = "conf_ddl";

fn column(name: &str, normalized_type: NormalizedType) -> DdlColumnDef {
    DdlColumnDef {
        name: name.to_string(),
        normalized_type,
        nullable: true,
        default: None,
        enum_values: None,
    }
}

fn ddl(op: SchemaDdlOp) -> SchemaDdlRequest {
    SchemaDdlRequest {
        op,
        table: DDL_TABLE.to_string(),
        column: None,
        column_name: None,
        columns: None,
        primary_key: None,
    }
}

async fn apply(
    pool: &dyn EnginePool,
    id: &RequestIdentity,
    req: SchemaDdlRequest,
) -> Result<(), String> {
    let op = format!("{:?}", req.op);
    pool.apply_schema_ddl(req, id.clone())
        .await
        .map(|_| ())
        .map_err(|e| format!("{op}: {e}"))
}

async fn describe(pool: &dyn EnginePool, id: &RequestIdentity) -> Result<SchemaDescriptor, String> {
    pool.describe_schema(id.clone())
        .await
        .map_err(|e| format!("describe_schema: {e}"))
}

/// The DDL table's column → normalized type, or None when describe omits it.
async fn ddl_columns(
    pool: &dyn EnginePool,
    id: &RequestIdentity,
) -> Result<Option<Vec<(String, NormalizedType)>>, String> {
    let schema = describe(pool, id).await?;
    Ok(schema
        .tables
        .into_iter()
        .find(|t| t.name == DDL_TABLE)
        .map(|t| {
            t.columns
                .into_iter()
                .map(|c| (c.name, c.normalized_type))
                .collect()
        }))
}

fn has_column(cols: &[(String, NormalizedType)], name: &str, types: &[NormalizedType]) -> bool {
    cols.iter().any(|(n, t)| n == name && types.contains(t))
}

/// Create → add column → drop column → drop table, each step read back
/// through describe. Columns are checked as a subset: an owner-scoped mount
/// may add `owner_id`, and mongo's key is `_id`.
pub(crate) async fn check_ddl_round_trip(
    pool: &dyn EnginePool,
    id: &RequestIdentity,
) -> Result<(), String> {
    let _ = apply(pool, id, ddl(SchemaDdlOp::DropTable)).await;
    let mut create = ddl(SchemaDdlOp::CreateTable);
    create.columns = Some(vec![
        column("id", NormalizedType::Integer),
        column("label", NormalizedType::Text),
    ]);
    create.primary_key = Some(vec!["id".to_string()]);
    apply(pool, id, create).await?;
    let cols = ddl_columns(pool, id)
        .await?
        .ok_or("created table not described")?;
    let int_types = [NormalizedType::Integer, NormalizedType::Bigint];
    if !has_column(&cols, "id", &int_types) || !has_column(&cols, "label", &[NormalizedType::Text])
    {
        return Err(format!("created columns read back wrong: {cols:?}"));
    }
    let mut add = ddl(SchemaDdlOp::AddColumn);
    add.column = Some(column("note", NormalizedType::Text));
    apply(pool, id, add).await?;
    let cols = ddl_columns(pool, id)
        .await?
        .ok_or("table lost after AddColumn")?;
    if !has_column(&cols, "note", &[NormalizedType::Text]) {
        return Err(format!("added column not described: {cols:?}"));
    }
    let mut drop = ddl(SchemaDdlOp::DropColumn);
    drop.column_name = Some("note".to_string());
    apply(pool, id, drop).await?;
    let cols = ddl_columns(pool, id)
        .await?
        .ok_or("table lost after DropColumn")?;
    if cols.iter().any(|(n, _)| n == "note") {
        return Err(format!("dropped column still described: {cols:?}"));
    }
    apply(pool, id, ddl(SchemaDdlOp::DropTable)).await?;
    match ddl_columns(pool, id).await? {
        Some(_) => Err("dropped table still described".to_string()),
        None => Ok(()),
    }
}

/// Engine dialect for the FK pair: (create parent, create child, drop child,
/// drop parent). None ⇒ the engine has no FK concept to introspect.
fn fk_sql(engine: &str) -> Option<[&'static str; 4]> {
    match engine {
        "postgresql" | "cockroachdb" => Some([
            "CREATE TABLE public.conf_fk_parent (id integer PRIMARY KEY)",
            "CREATE TABLE public.conf_fk_child (id integer PRIMARY KEY, \
             parent_id integer REFERENCES public.conf_fk_parent(id))",
            "DROP TABLE IF EXISTS public.conf_fk_child",
            "DROP TABLE IF EXISTS public.conf_fk_parent",
        ]),
        "mysql" | "mariadb" => Some([
            "CREATE TABLE conf_fk_parent (id int PRIMARY KEY) ENGINE=InnoDB",
            "CREATE TABLE conf_fk_child (id int PRIMARY KEY, parent_id int, \
             FOREIGN KEY (parent_id) REFERENCES conf_fk_parent(id)) ENGINE=InnoDB",
            "DROP TABLE IF EXISTS conf_fk_child",
            "DROP TABLE IF EXISTS conf_fk_parent",
        ]),
        "sqlite" => Some([
            "CREATE TABLE conf_fk_parent (id integer PRIMARY KEY)",
            "CREATE TABLE conf_fk_child (id integer PRIMARY KEY, \
             parent_id integer REFERENCES conf_fk_parent(id))",
            "DROP TABLE IF EXISTS conf_fk_child",
            "DROP TABLE IF EXISTS conf_fk_parent",
        ]),
        "mssql" => Some([
            "CREATE TABLE conf_fk_parent (id int PRIMARY KEY)",
            "CREATE TABLE conf_fk_child (id int PRIMARY KEY, \
             parent_id int REFERENCES conf_fk_parent(id))",
            "IF OBJECT_ID('conf_fk_child','U') IS NOT NULL DROP TABLE conf_fk_child",
            "IF OBJECT_ID('conf_fk_parent','U') IS NOT NULL DROP TABLE conf_fk_parent",
        ]),
        _ => None,
    }
}

/// A declared foreign key must surface in describe as the child column's
/// `references`, so a UI or migrator can follow the relation.
pub(crate) async fn check_fk_introspection(
    pool: &dyn EnginePool,
    id: &RequestIdentity,
    engine: &str,
) -> Result<(), String> {
    let Some([parent, child, drop_child, drop_parent]) = fk_sql(engine) else {
        return Ok(());
    };
    let _ = raw(pool, drop_child, id).await;
    let _ = raw(pool, drop_parent, id).await;
    raw(pool, parent, id)
        .await
        .map_err(|e| format!("create parent: {e}"))?;
    raw(pool, child, id)
        .await
        .map_err(|e| format!("create child: {e}"))?;
    let outcome = fk_described(pool, id).await;
    let _ = raw(pool, drop_child, id).await;
    let _ = raw(pool, drop_parent, id).await;
    outcome
}

async fn fk_described(pool: &dyn EnginePool, id: &RequestIdentity) -> Result<(), String> {
    let schema = describe(pool, id).await?;
    let column = schema
        .tables
        .iter()
        .find(|t| t.name == "conf_fk_child")
        .and_then(|t| t.columns.iter().find(|c| c.name == "parent_id"))
        .ok_or("conf_fk_child.parent_id not described")?;
    match &column.references {
        Some(r) if r.table == "conf_fk_parent" && r.column == "id" => Ok(()),
        other => Err(format!(
            "conf_fk_child.parent_id references {other:?}, want conf_fk_parent.id"
        )),
    }
}

fn is_refusal(e: &DataPlaneError) -> bool {
    matches!(
        e,
        DataPlaneError::NotImplemented { .. }
            | DataPlaneError::UnsupportedCapability { .. }
            | DataPlaneError::CapabilityGated { .. }
    )
}

fn refused<T>(route: &str, outcome: Result<T, DataPlaneError>) -> Result<(), String> {
    match outcome {
        Err(e) if is_refusal(&e) => Ok(()),
        Err(e) => Err(format!(
            "{route}=false refused with a non-refusal error: {e}"
        )),
        Ok(_) => Err(format!(
            "descriptor says {route}=false, but the pool served it"
        )),
    }
}

/// Route honesty: the operation-level `check_honesty` covers DataOperationKind;
/// this covers the route flags (introspect, schema_ddl, transactions, ddl).
/// Every flag marked false must refuse with a typed refusal — an Ok or an
/// engine error means the descriptor and the adapter disagree.
pub(crate) async fn check_route_honesty(
    pool: &dyn EnginePool,
    id: &RequestIdentity,
    caps: &EngineCapabilities,
    begin: TxBeginRequest,
) -> Result<(), String> {
    if !caps.introspect {
        refused("introspect", pool.describe_schema(id.clone()).await)?;
    }
    if !caps.schema_ddl {
        let mut probe = ddl(SchemaDdlOp::DropTable);
        probe.table = "conf_honesty".to_string();
        refused("schema_ddl", pool.apply_schema_ddl(probe, id.clone()).await)?;
    }
    if !caps.transactions {
        refused("transactions", pool.begin(begin).await)?;
    }
    if !caps.ddl {
        let probe = MigrationRequest {
            name: "conf_honesty".to_string(),
            statements: vec![],
        };
        refused("ddl", pool.apply_migration(probe, id.clone()).await)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refusal_variants_pass_and_others_fail() {
        let gated = DataPlaneError::CapabilityGated {
            capability: "ddl".to_string(),
        };
        assert!(refused::<()>("ddl", Err(gated)).is_ok());
        let served: Result<(), DataPlaneError> = Ok(());
        assert!(refused("ddl", served).is_err());
        let backend = DataPlaneError::Backend {
            message: "boom".to_string(),
        };
        assert!(refused::<()>("ddl", Err(backend)).is_err());
    }

    #[test]
    fn every_fk_dialect_drops_child_before_parent() {
        for engine in [
            "postgresql",
            "cockroachdb",
            "mysql",
            "mariadb",
            "sqlite",
            "mssql",
        ] {
            let [_, _, drop_child, drop_parent] = fk_sql(engine).expect(engine);
            assert!(drop_child.contains("conf_fk_child"), "{engine}");
            assert!(drop_parent.contains("conf_fk_parent"), "{engine}");
        }
        assert!(fk_sql("mongodb").is_none());
    }
}
