-- Group by UTC receipt day. Keep app time and engine time separate because they overlap.
SELECT date(received_at_ms / 1000, 'unixepoch') AS received_day_utc,
       COUNT(DISTINCT install_id) AS reporting_installs,
       COUNT(DISTINCT install_id) FILTER (WHERE kind = 'app_start') AS installs_reporting_launches,
       COALESCE(SUM(launch_count) FILTER (WHERE kind = 'app_start'), 0) AS launches,
       COALESCE(SUM(duration_ms) FILTER (WHERE kind = 'app_usage'), 0) AS app_duration_ms,
       COALESCE(SUM(duration_ms) FILTER (WHERE kind = 'engine_usage'), 0) AS engine_duration_ms
FROM telemetry_events
GROUP BY received_day_utc
ORDER BY received_day_utc DESC;
