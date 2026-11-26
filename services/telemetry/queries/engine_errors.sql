-- These streams can describe the same underlying failure. Report their counts separately.
SELECT engine,
       game_name,
       error_code,
       COUNT(*) FILTER (WHERE kind = 'engine_start') AS failed_starts,
       COUNT(*) FILTER (WHERE kind = 'engine_error') AS reported_errors
FROM telemetry_events
WHERE (kind = 'engine_start' AND success = 0) OR kind = 'engine_error'
GROUP BY engine, game_name, error_code
ORDER BY engine, failed_starts DESC, reported_errors DESC, game_name, error_code;
