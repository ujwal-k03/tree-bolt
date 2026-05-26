-- Outer CTE `t2` is visible from inside the derived table because the inner
-- WITH only declares an unrelated `t3`.
WITH t2 AS (
    SELECT 1
)
SELECT *
FROM (
    WITH t3 AS (
        SELECT 2
    )
    SELECT * FROM t2
) AS der_1;
