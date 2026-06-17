/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   trigger.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! SQL trigger generation for `PostgreSQL` LISTEN/NOTIFY.

/// Generate the SQL DDL for the notification trigger function.
///
/// Returns a complete SQL script that:
/// 1. Creates `realtime_notify()` trigger function.
/// 2. Drops any existing trigger on the table.
/// 3. Creates a new `AFTER INSERT OR UPDATE OR DELETE` trigger.
pub fn generate_trigger_sql(table: &str, channel: &str) -> String {
    format!("{}\n{}", notify_function_sql(channel), trigger_ddl(table),)
}

fn notify_function_sql(channel: &str) -> String {
    format!(
        r"
CREATE OR REPLACE FUNCTION realtime_notify() RETURNS trigger AS $$
DECLARE
  payload json;
BEGIN
  payload = json_build_object(
    'table', TG_TABLE_NAME,
    'schema', TG_TABLE_SCHEMA,
    'operation', TG_OP,
    'data', CASE
      WHEN TG_OP = 'DELETE' THEN row_to_json(OLD)
      ELSE row_to_json(NEW)
    END,
    'old_data', CASE
      WHEN TG_OP = 'UPDATE' THEN row_to_json(OLD)
      ELSE NULL
    END
  );
  PERFORM pg_notify('{channel}', payload::text);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;",
    )
}

fn trigger_ddl(table: &str) -> String {
    format!(
        r"
DROP TRIGGER IF EXISTS {table}_realtime ON {table};
CREATE TRIGGER {table}_realtime
  AFTER INSERT OR UPDATE OR DELETE ON {table}
  FOR EACH ROW EXECUTE FUNCTION realtime_notify();
",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_trigger_sql() {
        let sql = generate_trigger_sql("orders", "realtime_events");
        assert!(sql.contains("CREATE TRIGGER orders_realtime"));
        assert!(sql.contains("pg_notify('realtime_events'"));
        assert!(sql.contains("AFTER INSERT OR UPDATE OR DELETE ON orders"));
    }
}
