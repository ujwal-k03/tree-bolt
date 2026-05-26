# Dialect notes

Cross-dialect (MySQL vs Trino) edge cases observed while building the resolver.
These are not all "valid" or "invalid" outright - the behaviour depends on the
dialect. Captured here so we can decide what semantics this resolver should
follow when each one comes up.

## CTE inside a derived table

```sql
-- Throws in MySQL, OK in Trino
SELECT * FROM (
    WITH ujwal_t3 AS (
        SELECT 1 AS id, 2 AS t2_id
    )
    SELECT ujwal_t3.* FROM scrap.ujwal_t3, ujwal_t3 LIMIT 10
) AS T;
```

```sql
-- Throws in both: outer SELECT references `id`, but the derived table only
-- exposes whatever `ujwal_t3.*` resolved to, and that resolution is itself
-- ambiguous (CTE vs base table).
SELECT id FROM (
    WITH ujwal_t3 AS (
        SELECT 1 AS id, 2 AS t2_id
    )
    SELECT ujwal_t3.* FROM scrap.ujwal_t3, ujwal_t3 LIMIT 10
) AS T;
```

## Ambiguous column after `WITH` shadow

```sql
-- Ambiguous in both dialects: `id` exists on both the CTE and the base table
-- when `ujwal_t3` resolves to two distinct sources in the same FROM.
WITH ujwal_t3 AS (
    SELECT 1 AS id, 2 AS t2_id
)
SELECT ujwal_t3.id FROM scrap.ujwal_t3, ujwal_t3 LIMIT 10;
```

```sql
-- Fine: the CTE's column is `_id`, so `ujwal_t3.id` unambiguously binds to
-- the base table.
WITH ujwal_t3 AS (
    SELECT 1 AS _id, 2 AS t2_id
)
SELECT ujwal_t3.id FROM scrap.ujwal_t3, ujwal_t3 LIMIT 10;
```

## Tuple-form `IN` against a subquery

```sql
-- Invalid: a scalar LHS cannot match a row-returning subquery directly.
SELECT * FROM scrap.ujwal_t3
WHERE t2_id IN (SELECT * FROM scrap.ujwal_t2);

-- Valid: tuple LHS matches the row shape of the subquery.
SELECT * FROM scrap.ujwal_t3
WHERE (t2_id, id) IN (SELECT * FROM scrap.ujwal_t2);

-- OK in MySQL, not in Trino: mixed literal + column tuple.
SELECT * FROM scrap.ujwal_t3
WHERE ('4', id) IN (SELECT * FROM scrap.ujwal_t2);
```

## Scalar subquery in the SELECT list

```sql
-- OK in Trino, not in MySQL (without LIMIT 1 the subquery may yield >1 row).
SELECT (SELECT * FROM scrap.ujwal_t2 LIMIT 1) FROM scrap.ujwal_t3;

SELECT id,
       (SELECT id FROM scrap.ujwal_t2 LIMIT 1) AS t2_id
FROM scrap.ujwal_t3;
```
