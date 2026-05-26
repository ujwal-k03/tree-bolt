-- Inner `SELECT * FROM t3` references a name that neither the outer CTE (`t2`)
-- nor the inner CTE (`t2`) provides - should fail resolution.
WITH t2 AS (
    SELECT 1
)
SELECT *
FROM (
    WITH t2 AS (
        SELECT 2
    )
    SELECT * FROM t3
) AS der_1;
