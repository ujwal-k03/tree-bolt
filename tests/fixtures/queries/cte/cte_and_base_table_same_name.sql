-- CTE `ujwal_t3` defined alongside a base table `scrap.ujwal_t3`. The FROM
-- references both - the unqualified `ujwal_t3` should bind to the CTE.
WITH ujwal_t3 AS (
    SELECT 1 AS id, 2 AS t2_id
)
SELECT ujwal_t3.* FROM scrap.ujwal_t3, ujwal_t3 LIMIT 10;
