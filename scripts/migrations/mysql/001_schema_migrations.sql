CREATE TABLE IF NOT EXISTS schema_migrations (
  version     INT PRIMARY KEY,
  name        VARCHAR(255) NOT NULL,
  applied_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

INSERT INTO schema_migrations (version, name)
VALUES (1, '001_schema_migrations')
ON DUPLICATE KEY UPDATE name = VALUES(name);