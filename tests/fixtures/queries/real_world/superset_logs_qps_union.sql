WITH second_bins AS (
    -- Superset queries
        SELECT
            date_trunc('second', dttm) AS second_bin,
            count(1) AS queries_per_second
        FROM silver.supersetprod__logs
        WHERE dttm >= timestamp '2025-09-01 00:00:00.000 +0530'
          AND dttm < timestamp '2026-01-01 00:00:00.000 +0530'
        GROUP BY 1
        
    UNION ALL
    
    -- MBPRI queries
    SELECT
        date_trunc('second', create_time) AS second_bin,
        count(1) AS queries_per_second
    FROM presto_read.public.completed_queries
    WHERE create_time >= timestamp '2025-09-01 00:00:00.000 +0530'
      AND create_time < timestamp '2026-01-01 00:00:00.000 +0530'
      AND environment IN ('osstrinombpribk1', 'osstrinombpribk2')
    GROUP BY 1
    
    UNION ALL
    
    -- MBSEC queries
    SELECT
        date_trunc('second', create_time) AS second_bin,
        count(1) AS queries_per_second
    FROM trino_mb_sec.public.completed_queries
    WHERE create_time >= timestamp '2025-09-01 00:00:00.000 +0530'
      AND create_time < timestamp '2026-01-01 00:00:00.000 +0530'
      AND environment IN ('osmbs1', 'osmbs2')
    GROUP BY 1
    
    UNION ALL
    
    -- MBEXT queries
    SELECT
        date_trunc('second', create_time) AS second_bin,
        count(1) AS queries_per_second
    FROM trino_zeppelin_os.public.completed_queries
    WHERE create_time >= timestamp '2025-09-01 00:00:00.000 +0530'
      AND create_time < timestamp '2026-01-01 00:00:00.000 +0530'
      AND environment INa ('osmbextbk1', 'oszepbk2')
    GROUP BY 1
    
    UNION ALL
    
    -- Spark zeppelin queries
    SELECT date_trunc('second', CAST(from_unixtime(query_start_time_ms / 1000) AS TIMESTAMP)) AS second_bin, count(1) AS queries_per_second
    FROM gold.zeppline_spark_query_history
    WHERE date >= '20250901'
    AND date < '20260101'
    GROUP BY 1
),
aggregated_seconds AS (
    SELECT 
        second_bin,
        sum(queries_per_second) AS total_qps
    FROM second_bins
    GROUP BY second_bin
)
SELECT 
    'Peak QPS' AS metric,
    to_iso8601(second_bin) AS peak_time,
    total_qps AS queries_count
FROM aggregated_seconds
ORDER BY total_qps DESC
LIMIT 1000