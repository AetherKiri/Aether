-- NULL game_name means the client omitted the title.
SELECT engine,
       game_name,
       COUNT(*) AS attempts,
       SUM(success) AS successes,
       ROUND(100.0 * AVG(success), 1) AS success_percent,
       ROUND(AVG(load_ms) FILTER (WHERE success = 1), 1) AS average_successful_load_ms
FROM telemetry_events
WHERE kind = 'engine_start'
GROUP BY engine, game_name
ORDER BY engine, attempts DESC, game_name;
