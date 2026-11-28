CREATE TABLE telemetry_events (
    event_id TEXT PRIMARY KEY NOT NULL,
    install_id TEXT NOT NULL,
    schema_version INTEGER NOT NULL CHECK (schema_version = 1),
    received_at_ms INTEGER NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('app_start', 'app_usage', 'engine_start', 'engine_usage', 'engine_error')),
    os TEXT NOT NULL,
    arch TEXT NOT NULL,
    ram_bucket TEXT NOT NULL,
    gpu_family TEXT NOT NULL,
    app_version TEXT NOT NULL,
    build TEXT NOT NULL,
    channel TEXT NOT NULL,
    launch_count INTEGER CHECK (launch_count = 1),
    duration_ms INTEGER,
    fps INTEGER,
    memory_peak_mb INTEGER,
    engine TEXT,
    game_name TEXT,
    success INTEGER CHECK (success IN (0, 1)),
    load_ms INTEGER,
    error_code TEXT
) STRICT;

CREATE INDEX telemetry_events_received_at ON telemetry_events (received_at_ms);
