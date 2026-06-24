//! PB JS hooks: `pb_hooks/*.pb.js` on an embedded QuickJS runtime.
//!
//! One OS thread owns the runtime (PB's goja pool ≈ our serialized queue —
//! `ONE_HOOKS_POOL` can grow it later); jobs cross via channels as JSON
//! strings, so no JS value ever leaves the thread. Surface v1 (PB names):
//!   - `onRecordCreateRequest(fn, ...collections)` / Update / Delete —
//!     handlers receive `e = {collection, record}`, may MUTATE `e.record`,
//!     and `throw` to reject the request (PB semantics);
//!   - `routerAdd(method, path, fn)` — custom endpoints under the /api
//!     fallback; the handler gets `{method, path, query, body}` and returns
//!     `{status?, body?}`;
//!   - `cronAdd(id, expr, fn)` — 5-field cron, checked on a 60 s tick;
//!   - `$app.createRecord/listRecords/updateRecord` (engine-backed),
//!     `console.log` → tracing.
//!
//! Zero cost when absent: with no hooks dir the dispatcher publishes empty
//! registries and the hot path pays one atomic load. Runaway scripts hit a
//! 500 ms interrupt deadline. Files reload when an mtime changes (~2 s
//! poll), exactly PB's `--hooksWatch` behavior.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Mutex;

use crate::routes::AppState;

pub(crate) const ACT_CREATE: u8 = 1;
pub(crate) const ACT_UPDATE: u8 = 2;
pub(crate) const ACT_DELETE: u8 = 4;

pub(crate) struct Hooks {
    tx: std::sync::mpsc::Sender<Job>,
    /// Bitmask of record actions with at least one handler.
    active: AtomicU8,
    /// "METHOD /path" route keys registered by routerAdd.
    routes: Mutex<std::collections::HashSet<String>>,
}

enum Job {
    Record {
        action: &'static str,
        collection: String,
        record: String,
        reply: std::sync::mpsc::Sender<Result<String, String>>,
    },
    Route {
        key: String,
        request: String,
        reply: std::sync::mpsc::Sender<Result<String, String>>,
    },
    CronTick,
}

impl Hooks {
    pub(crate) fn active_for(&self, action: u8) -> bool {
        self.active.load(Ordering::Relaxed) & action != 0
    }

    pub(crate) fn has_route(&self, method: &str, path: &str) -> bool {
        self.routes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(&format!("{method} {path}"))
    }

    /// Fire a record hook; Ok(Some(json)) = (possibly mutated) record,
    /// Err(msg) = the hook rejected the operation.
    pub(crate) async fn fire_record(
        &self,
        action: &'static str,
        collection: &str,
        record: &Value,
    ) -> Result<Option<Value>, String> {
        let (reply, rx) = std::sync::mpsc::channel();
        let job = Job::Record {
            action,
            collection: collection.to_string(),
            record: record.to_string(),
            reply,
        };
        if self.tx.send(job).is_err() {
            return Ok(None); // hooks thread gone: fail open for events
        }
        let got = tokio::task::spawn_blocking(move || {
            rx.recv_timeout(std::time::Duration::from_secs(2))
        })
        .await
        .map_err(|_| "hooks join failed".to_string())?;
        match got {
            Ok(Ok(s)) => Ok(serde_json::from_str(&s).ok()),
            Ok(Err(m)) => Err(m),
            Err(_) => Ok(None), // timeout: the interrupt handler kills the script
        }
    }

    /// Serve a routerAdd route. Ok((status, body)).
    pub(crate) async fn serve_route(
        &self,
        method: &str,
        path: &str,
        query: &str,
        body: &Value,
    ) -> Result<(u16, Value), String> {
        let (reply, rx) = std::sync::mpsc::channel();
        let request = json!({ "method": method, "path": path, "query": query, "body": body });
        let job = Job::Route {
            key: format!("{method} {path}"),
            request: request.to_string(),
            reply,
        };
        self.tx.send(job).map_err(|_| "hooks thread gone".to_string())?;
        let got = tokio::task::spawn_blocking(move || {
            rx.recv_timeout(std::time::Duration::from_secs(2))
        })
        .await
        .map_err(|_| "hooks join failed".to_string())?;
        match got {
            Ok(Ok(s)) => {
                let v: Value = serde_json::from_str(&s).unwrap_or(json!({}));
                let status = v.get("status").and_then(Value::as_u64).unwrap_or(200) as u16;
                let body = v.get("body").cloned().unwrap_or(json!({}));
                Ok((status, body))
            }
            Ok(Err(m)) => Err(m),
            Err(_) => Err("hook route timed out".to_string()),
        }
    }
}

/// Registration data the JS prelude reports back while a file set loads.
#[derive(Default)]
struct Registry {
    record: Vec<(String, Vec<String>, usize)>, // action, collections, idx
    routes: HashMap<String, usize>,            // "METHOD /path" -> idx
    crons: Vec<(String, [String; 5], usize)>,  // id, expr fields, idx
}

const PRELUDE: &str = r#"
globalThis.__recordHandlers = [];
globalThis.__routeHandlers = [];
globalThis.__cronHandlers = [];
function __mkRecordHook(action) {
  return (fn, ...cols) => {
    __recordHandlers.push(fn);
    __reg('record', action, JSON.stringify(cols), __recordHandlers.length - 1);
  };
}
globalThis.onRecordCreateRequest = __mkRecordHook('create');
globalThis.onRecordUpdateRequest = __mkRecordHook('update');
globalThis.onRecordDeleteRequest = __mkRecordHook('delete');
globalThis.routerAdd = (method, path, fn) => {
  __routeHandlers.push(fn);
  __reg('route', String(method).toUpperCase() + ' ' + path, '[]', __routeHandlers.length - 1);
};
globalThis.cronAdd = (id, expr, fn) => {
  __cronHandlers.push(fn);
  __reg('cron', id + '|' + expr, '[]', __cronHandlers.length - 1);
};
globalThis.__dispatchRecord = (i, payload) => {
  const e = JSON.parse(payload);
  __recordHandlers[i](e);
  return JSON.stringify(e.record ?? null);
};
globalThis.__dispatchRoute = (i, payload) => {
  const out = __routeHandlers[i](JSON.parse(payload)) ?? {};
  return JSON.stringify(out);
};
globalThis.__dispatchCron = (i) => { __cronHandlers[i](); };
globalThis.console = {
  log: (...a) => __log(a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')),
  error: (...a) => __log('ERROR ' + a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')),
};
globalThis.$app = {
  createRecord: (col, data) => JSON.parse(__app_create(col, JSON.stringify(data))),
  listRecords: (col, filter) => JSON.parse(__app_list(col, filter ?? '')),
  updateRecord: (col, id, data) => JSON.parse(__app_update(col, id, JSON.stringify(data))),
};
"#;

/// Parse one 5-field cron expression field-by-field ("*", "*/n", "a,b", "n").
fn cron_field_matches(field: &str, value: u32) -> bool {
    if field == "*" {
        return true;
    }
    if let Some(step) = field.strip_prefix("*/") {
        return step.parse::<u32>().map(|s| s > 0 && value % s == 0).unwrap_or(false);
    }
    field
        .split(',')
        .any(|part| part.parse::<u32>().map(|n| n == value).unwrap_or(false))
}

fn cron_matches(fields: &[String; 5], t: chrono::DateTime<chrono::Utc>) -> bool {
    use chrono::{Datelike, Timelike};
    cron_field_matches(&fields[0], t.minute())
        && cron_field_matches(&fields[1], t.hour())
        && cron_field_matches(&fields[2], t.day())
        && cron_field_matches(&fields[3], t.month())
        && cron_field_matches(&fields[4], t.weekday().num_days_from_sunday())
}

fn dir_signature(dir: &std::path::Path) -> Vec<(String, std::time::SystemTime)> {
    let mut out = Vec::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if !name.ends_with(".pb.js") {
                continue;
            }
            if let Ok(meta) = e.metadata() {
                if let Ok(m) = meta.modified() {
                    out.push((name, m));
                }
            }
        }
    }
    out.sort();
    out
}

/// Boot the hooks engine. Returns None when the directory doesn't exist —
/// the truly-zero-cost path.
pub(crate) fn start(state: AppState, dir: std::path::PathBuf) -> Option<std::sync::Arc<Hooks>> {
    if !dir.is_dir() {
        return None;
    }
    let (tx, rx) = std::sync::mpsc::channel::<Job>();
    let hooks = std::sync::Arc::new(Hooks {
        tx: tx.clone(),
        active: AtomicU8::new(0),
        routes: Mutex::new(Default::default()),
    });
    let published = hooks.clone();
    let handle = tokio::runtime::Handle::current();

    std::thread::Builder::new()
        .name("pb-hooks-js".into())
        .spawn(move || run_js_thread(state, dir, rx, published, handle))
        .ok()?;

    // cron ticker: top of every minute
    let cron_tx = tx;
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        loop {
            interval.tick().await;
            if cron_tx.send(Job::CronTick).is_err() {
                return;
            }
        }
    });
    Some(hooks)
}

fn run_js_thread(
    state: AppState,
    dir: std::path::PathBuf,
    rx: std::sync::mpsc::Receiver<Job>,
    published: std::sync::Arc<Hooks>,
    handle: tokio::runtime::Handle,
) {
    use rquickjs::{Context, Function, Runtime};

    let deadline = std::sync::Arc::new(Mutex::new(std::time::Instant::now() + std::time::Duration::from_secs(3600)));

    type SharedRegistry = std::rc::Rc<std::cell::RefCell<Registry>>;
    let build = |sig: &Vec<(String, std::time::SystemTime)>| -> Option<(Runtime, Context, SharedRegistry)> {
        // the interrupt deadline is SHARED with job execution — the last job
        // left it ~500 ms in the past, which aborted reload evals until this
        // re-arm (the m51 reload lane caught it)
        arm(&deadline, 10_000);
        let rt = Runtime::new().ok()?;
        let dl = deadline.clone();
        rt.set_interrupt_handler(Some(Box::new(move || {
            std::time::Instant::now()
                > *dl.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
        })));
        let ctx = Context::full(&rt).ok()?;
        let registry = std::rc::Rc::new(std::cell::RefCell::new(Registry::default()));

        ctx.with(|ctx| -> Option<()> {
            let globals = ctx.globals();
            let reg = registry.clone();
            globals
                .set(
                    "__reg",
                    Function::new(ctx.clone(), move |kind: String, key: String, cols: String, idx: i32| {
                        let mut r = reg.borrow_mut();
                        match kind.as_str() {
                            "record" => {
                                let cols: Vec<String> =
                                    serde_json::from_str(&cols).unwrap_or_default();
                                r.record.push((key, cols, idx as usize));
                            }
                            "route" => {
                                r.routes.insert(key, idx as usize);
                            }
                            "cron" => {
                                if let Some((id, expr)) = key.split_once('|') {
                                    let fields: Vec<String> =
                                        expr.split_whitespace().map(String::from).collect();
                                    if fields.len() == 5 {
                                        let arr: [String; 5] = [
                                            fields[0].clone(),
                                            fields[1].clone(),
                                            fields[2].clone(),
                                            fields[3].clone(),
                                            fields[4].clone(),
                                        ];
                                        r.crons.push((id.to_string(), arr, idx as usize));
                                    }
                                }
                            }
                            _ => {}
                        }
                    })
                    .ok()?,
                )
                .ok()?;
            globals
                .set(
                    "__log",
                    Function::new(ctx.clone(), |msg: String| {
                        tracing::info!(target: "pb_hooks", "{msg}");
                    })
                    .ok()?,
                )
                .ok()?;
            // $app bindings: block on the engine through the runtime handle.
            let st = state.clone();
            let h = handle.clone();
            globals
                .set(
                    "__app_create",
                    Function::new(ctx.clone(), move |col: String, data: String| -> String {
                        app_create(&st, &h, &col, &data)
                    })
                    .ok()?,
                )
                .ok()?;
            let st = state.clone();
            let h = handle.clone();
            globals
                .set(
                    "__app_list",
                    Function::new(ctx.clone(), move |col: String, filter: String| -> String {
                        app_list(&st, &h, &col, &filter)
                    })
                    .ok()?,
                )
                .ok()?;
            let st = state.clone();
            let h = handle.clone();
            globals
                .set(
                    "__app_update",
                    Function::new(ctx.clone(), move |col: String, id: String, data: String| -> String {
                        app_update(&st, &h, &col, &id, &data)
                    })
                    .ok()?,
                )
                .ok()?;
            ctx.eval::<(), _>(PRELUDE).ok()?;
            for (name, _) in sig {
                let path = dir.join(name);
                let Ok(src) = std::fs::read_to_string(&path) else { continue };
                if let Err(e) = ctx.eval::<(), _>(src.as_bytes()) {
                    tracing::warn!(target: "pb_hooks", file = %name, "hook file failed to load: {e}");
                }
            }
            Some(())
        })?;

        // the prelude's closures hold Rc clones for the context's lifetime —
        // the registry stays shared, readers borrow()
        Some((rt, ctx, registry))
    };

    let mut sig = dir_signature(&dir);
    let Some((mut _rt, mut ctx, mut registry)) = build(&sig) else {
        tracing::warn!(target: "pb_hooks", "hooks runtime failed to start");
        return;
    };
    publish(&published, &registry.borrow());
    {
        let r = registry.borrow();
        tracing::info!(target: "pb_hooks",
            records = r.record.len(), routes = r.routes.len(),
            crons = r.crons.len(), "pb_hooks loaded");
    }

    loop {
        let job = match rx.recv_timeout(std::time::Duration::from_secs(1)) {
            Ok(j) => Some(j),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => None,
            Err(e) => {
                tracing::info!(target: "pb_hooks", "hooks channel closed ({e:?}) — thread exiting");
                return;
            }
        };
        // hooksWatch: reload when the file set changes (the 1 s recv timeout
        // paces this check; no extra clock needed)
        let now_sig = dir_signature(&dir);
        if now_sig != sig {
            tracing::info!(target: "pb_hooks", "pb_hooks change detected — reloading");
            sig = now_sig;
            if let Some((nrt, nctx, nreg)) = build(&sig) {
                _rt = nrt;
                ctx = nctx;
                registry = nreg;
                publish(&published, &registry.borrow());
                tracing::info!(target: "pb_hooks", "pb_hooks reloaded");
            } else {
                tracing::warn!(target: "pb_hooks", "pb_hooks reload failed — keeping the old set");
            }
        }
        let Some(job) = job else { continue };
        arm(&deadline, 500);
        match job {
            Job::Record { action, collection, record, reply } => {
                let mut current = record;
                let mut failed = None;
                let handlers: Vec<(String, Vec<String>, usize)> =
                    registry.borrow().record.clone();
                for (act, cols, idx) in &handlers {
                    if act != action || !(cols.is_empty() || cols.contains(&collection)) {
                        continue;
                    }
                    let payload = json!({ "collection": collection, "record": serde_json::from_str::<Value>(&current).unwrap_or(Value::Null) }).to_string();
                    let res: Result<String, _> = ctx.with(|ctx| {
                        let f: rquickjs::Function = ctx.globals().get("__dispatchRecord")?;
                        f.call((*idx as i32, payload.as_str()))
                    });
                    match res {
                        Ok(s) => current = s,
                        Err(_) => {
                            let msg = ctx.with(|ctx| {
                                ctx.catch()
                                    .get::<rquickjs::Object>()
                                    .ok()
                                    .and_then(|o| o.get::<_, String>("message").ok())
                                    .unwrap_or_else(|| "hook rejected the request".into())
                            });
                            failed = Some(msg);
                            break;
                        }
                    }
                }
                let _ = reply.send(match failed {
                    Some(m) => Err(m),
                    None => Ok(current),
                });
            }
            Job::Route { key, request, reply } => {
                let idx_opt = registry.borrow().routes.get(&key).copied();
                let out = match idx_opt.as_ref() {
                    Some(idx) => ctx
                        .with(|ctx| {
                            let f: rquickjs::Function = ctx.globals().get("__dispatchRoute")?;
                            f.call::<_, String>((*idx as i32, request.as_str()))
                        })
                        .map_err(|_| "hook route failed".to_string()),
                    None => Err("no such route".to_string()),
                };
                let _ = reply.send(out);
            }
            Job::CronTick => {
                let now = chrono::Utc::now();
                let crons: Vec<(String, [String; 5], usize)> = registry.borrow().crons.clone();
                for (id, fields, idx) in &crons {
                    if cron_matches(fields, now) {
                        let res: Result<(), _> = ctx.with(|ctx| {
                            let f: rquickjs::Function = ctx.globals().get("__dispatchCron")?;
                            f.call((*idx as i32,))
                        });
                        if res.is_err() {
                            tracing::warn!(target: "pb_hooks", cron = %id, "cron hook failed");
                        }
                    }
                }
            }
        }
    }
}

fn arm(deadline: &std::sync::Arc<Mutex<std::time::Instant>>, ms: u64) {
    *deadline.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
        std::time::Instant::now() + std::time::Duration::from_millis(ms);
}

fn publish(hooks: &Hooks, registry: &Registry) {
    let mut mask = 0u8;
    for (action, _, _) in &registry.record {
        mask |= match action.as_str() {
            "create" => ACT_CREATE,
            "update" => ACT_UPDATE,
            "delete" => ACT_DELETE,
            _ => 0,
        };
    }
    hooks.active.store(mask, Ordering::Relaxed);
    *hooks
        .routes
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) =
        registry.routes.keys().cloned().collect();
}

// ── $app engine bridges (called from the JS thread; block on the handle) ────

fn app_create(state: &AppState, handle: &tokio::runtime::Handle, col: &str, data: &str) -> String {
    let Ok(data) = serde_json::from_str::<Value>(data) else {
        return json!({"error": "bad data"}).to_string();
    };
    let mut op = super::records::base_op_pub(data_plane_core::DataOperationKind::Insert, col);
    let mut obj = data.as_object().cloned().unwrap_or_default();
    let id = super::pb_id();
    obj.insert("id".into(), json!(id));
    op.data = Some(Value::Object(obj));
    let state = state.clone();
    let res = handle.block_on(async move { super::exec(&state, op).await });
    match res {
        Ok(_) => json!({"id": id}).to_string(),
        Err(_) => json!({"error": "create failed"}).to_string(),
    }
}

fn app_list(state: &AppState, handle: &tokio::runtime::Handle, col: &str, filter: &str) -> String {
    let mut op = super::records::base_op_pub(data_plane_core::DataOperationKind::List, col);
    if !filter.trim().is_empty() {
        match super::filter::parse_pb_filter(filter) {
            Ok(ast) => op.filter = Some(super::records::filter_to_wire(&ast)),
            Err(_) => return "[]".to_string(),
        }
    }
    op.limit = Some(100);
    let state = state.clone();
    let res = handle.block_on(async move { super::exec(&state, op).await });
    match res {
        Ok(r) => Value::Array(r.rows).to_string(),
        Err(_) => "[]".to_string(),
    }
}

fn app_update(state: &AppState, handle: &tokio::runtime::Handle, col: &str, id: &str, data: &str) -> String {
    let Ok(data) = serde_json::from_str::<Value>(data) else {
        return json!({"error": "bad data"}).to_string();
    };
    let mut op = super::records::base_op_pub(data_plane_core::DataOperationKind::Update, col);
    op.data = Some(data);
    op.filter = Some(json!({ "id": id }));
    let state = state.clone();
    let res = handle.block_on(async move { super::exec(&state, op).await });
    match res {
        Ok(r) => json!({"affected": r.affected_rows}).to_string(),
        Err(_) => json!({"error": "update failed"}).to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cron_fields() {
        assert!(cron_field_matches("*", 7));
        assert!(cron_field_matches("*/5", 10));
        assert!(!cron_field_matches("*/5", 11));
        assert!(cron_field_matches("3,7,9", 7));
        assert!(!cron_field_matches("3,7,9", 8));
    }
}
