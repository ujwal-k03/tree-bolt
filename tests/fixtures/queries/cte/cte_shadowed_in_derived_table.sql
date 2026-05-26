-- Outer CTE `t2` is shadowed by an inner CTE `t2` inside the derived table.
-- The inner `SELECT * FROM t2` must bind to the inner CTE.
WITH t2 AS (
    SELECT 1
)
SELECT *
FROM (
    WITH t2 AS (
        SELECT 2
    )
    SELECT * FROM t2
) AS der_1;
