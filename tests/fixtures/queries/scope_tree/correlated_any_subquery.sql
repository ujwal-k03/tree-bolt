-- Correlated subquery via `= ANY`: the inner WHERE references `Table_1.column_2`
-- from the outer scope.
SELECT *
FROM Table_1
WHERE column_1 = ANY (
    SELECT column_1
    FROM Table_2
    WHERE column_2 = Table_1.column_2
);
