-- Application and engine intervals are separate report groups.
SELECT kind,
       engine,
       game_name,
       COUNT(*) AS usage_intervals,
       COUNT(fps) AS fps_intervals,
       ROUND(SUM(1.0 * fps * duration_ms) / NULLIF(SUM(duration_ms) FILTER (WHERE fps IS NOT NULL), 0), 1)
           AS duration_weighted_fps,
       COUNT(memory_peak_mb) AS memory_intervals,
       MAX(memory_peak_mb) AS peak_memory_mb
FROM telemetry_events
WHERE kind IN ('app_usage', 'engine_usage')
GROUP BY kind, engine, game_name
ORDER BY kind, engine, game_name;
