-- Forward verification for com.zcore.zfishing/001-schema.
-- The Site Agent runs this after applying 001_schema.up.sql and asserts that
-- found_tables = 6 before marking the migration successful / schema-ready.
-- A value other than 6 means the schema is incomplete and the Agent must not
-- proceed (fail closed).

SELECT COUNT(*) AS found_tables
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_name IN (
    'zfishing_players',
    'zfishing_catches',
    'zfishing_settings',
    'zfishing_zones',
    'zfishing_fish',
    'zfishing_equipment'
  );
