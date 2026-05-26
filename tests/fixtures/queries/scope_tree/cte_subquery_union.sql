-- Scope tree test: Root + CTE + derived table + subquery + UNION
WITH cte AS (
  SELECT id, name FROM users
)
(
    SELECT *
    FROM cte
    JOIN (SELECT id FROM orders) AS ord ON cte.id = ord.id
    WHERE cte.id IN (SELECT user_id FROM logins)
)
UNION ALL
SELECT 1 AS id, 'x' AS name FROM other_table
