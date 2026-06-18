//! Response shaping — maps an upstream JSON body onto a [`DataResult`],
//! matching the legacy TS adapter's envelope handling.

use data_plane_core::DataResult;
use serde_json::Value;

pub(super) fn shape_response(parsed: Value) -> DataResult {
    // Match the TS adapter: array → rows; { data: [...] } → rows; object → 1
    // row; everything else → empty.
    match parsed {
        Value::Array(arr) => {
            let count = arr.len() as u64;
            DataResult::new(arr, count)
        }
        Value::Object(mut obj) => {
            if let Some(Value::Array(arr)) = obj.remove("data") {
                let count = arr.len() as u64;
                return DataResult::new(arr, count);
            }
            // Re-wrap (we consumed `data` if it existed).
            DataResult::new(vec![Value::Object(obj)], 1)
        }
        _ => DataResult::new(vec![], 0),
    }
}
