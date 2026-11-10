# SELECT-list back-references in GROUP BY / HAVING / ORDER BY

Spec for resolving positional and alias references back into the SELECT list. Covers what the forms are, what dialects allow them, **which name wins when an alias collides with an input column**, how they appear in the sqlparser AST, what the resolver does today, and the plan to fix the gap.

Every dialect claim below has one or both of these markers:

- 📄 **documented**: a quote from the vendor docs. The links are in [Sources](#sources).
- 🧪 **tested**: run against a real engine. See [Empirical results](#empirical-results). The engines tested were PostgreSQL 14.17, MySQL 9.2.0 (default `sql_mode`, so `ONLY_FULL_GROUP_BY` is on), SQLite 3.54.0 and DuckDB 1.1.3.

A cell with ❔ is neither documented nor tested. Don't build behaviour on it without checking it first.

## What is a "back-reference"?

A clause evaluated after the SELECT list can refer to a SELECT item instead of repeating its expression. There are two surface forms.

**Positional**: refers to a SELECT item by its 1-based index.
```sql
SELECT user_id, SUM(amount) AS total
FROM orders
GROUP BY 1               -- == GROUP BY user_id
ORDER BY 2 DESC;         -- == ORDER BY SUM(amount) DESC
```

**Alias**: refers to a SELECT item by its output name.
```sql
SELECT user_id, SUM(amount) AS total
FROM orders
GROUP BY user_id
HAVING total > 100       -- == HAVING SUM(amount) > 100   (not legal in Postgres)
ORDER BY total DESC;     -- == ORDER BY SUM(amount) DESC
```

When a back-reference is unambiguous, it is syntactic sugar for the SELECT item's expression, so lineage should produce the **same dependency set** as the de-sugared form.

When the name could also be an input (FROM) column, it is **not** sugar. The engine picks one meaning by a precedence rule, and that rule **differs by clause and by dialect**. See [Precedence](#precedence-when-an-alias-collides-with-an-input-column).

## Dialect support matrix

Whether the form is accepted at all.

| Dialect | ORDER BY alias | ORDER BY pos. | GROUP BY alias | GROUP BY pos. | HAVING alias |
|---|---|---|---|---|---|
| SQL-92 | ✅ 📄 | ✅ 📄 | ❌ 📄 | ❌ 📄 | ❌ 📄 |
| PostgreSQL | ✅ 📄🧪 | ✅ 📄🧪 | ✅ 📄🧪 | ✅ 🧪 | ❌ 📄🧪 |
| MySQL | ✅ 📄🧪 | ✅ (deprecated) 📄🧪 | ✅ 📄🧪 | ✅ (deprecated) 📄🧪 | ✅ 📄🧪 |
| SQLite | ✅ 📄🧪 | ✅ 📄🧪 | ✅ 🧪 | ✅ 📄🧪 | ✅ 🧪 |
| DuckDB | ✅ 🧪 | ✅ 📄🧪 | ✅ 📄🧪 | ✅ 🧪 | ✅ 📄🧪 |
| Trino | ✅ 📄 | ✅ 📄 | ❔ (docs list only input expressions and ordinals) | ✅ 📄 | ❔ |
| Spark / Databricks | ✅ 📄 | ✅ 📄 (`spark.sql.orderByOrdinal`) | ✅ 📄 (`spark.sql.groupByAliases`) | ✅ 📄 (`spark.sql.groupByOrdinal`) | ✅ 📄 |
| BigQuery | ✅ 📄 | ✅ 📄 | ✅ 📄 | ✅ 📄 | ✅ 📄 |
| Snowflake | ✅ 📄 | ✅ 📄 | ✅ 📄 | ✅ 📄 | ✅ 📄 |
| ClickHouse | ✅ 📄 (aliases are query-global) | ✅ 📄 (`enable_positional_arguments`) | ✅ 📄 | ✅ 📄 | ✅ 📄 (aliases are query-global) |
| Redshift | ❔ | ❔ | ❔ | ✅ 📄 | ❔ |
| SQL Server | ✅ 📄 | ✅ 📄 | ❌ 📄 | ❔ | ❔ |
| Oracle 23ai | ✅ 📄 | ✅ 📄 | ✅ 📄 (Release 23+) | ✅ only if `group_by_position_enabled = true` (default false) 📄 | ❔ |

Notes:
- **Positional ORDER BY and the standard.** SQL-92 allowed output-column numbers in ORDER BY. Later editions dropped them: the MySQL docs say "the syntax has been removed from the SQL standard". Neither source names the exact edition.
- **Postgres HAVING.** Postgres explicitly forbids output names in HAVING. `SELECT c, COUNT(*) AS n FROM t GROUP BY c HAVING n > 1` fails with `column "n" does not exist` 🧪.
- **Trino.** The SELECT docs say GROUP BY "may contain any expression composed of input columns or ... an ordinal number". They never mention aliases. Test against Trino before relying on GROUP BY alias or HAVING alias support.

**Takeaways:**
- ORDER BY back-references, in both forms, are effectively universal.
- GROUP BY back-references are widely supported but not universal: SQL Server rejects them, and Trino documents only ordinals.
- HAVING aliases vary the most: Postgres rejects them, and Trino is undocumented.
- This resolver is built against MySQL and Trino input (see [`tests/fixtures/queries/dialect_notes.md`](../tests/fixtures/queries/dialect_notes.md)). MySQL accepts all five forms. Trino is certain only for ORDER BY and GROUP BY ordinals.

## Precedence when an alias collides with an input column

This is the part that matters for lineage correctness. Take `t(a, b)` and the query `SELECT b AS a FROM t <clause> a`. Does `a` mean `t.a` or `t.b`? The rule depends on the clause.

### ORDER BY: a bare name resolves to the alias first

| Dialect | `SELECT b AS a FROM t ORDER BY a` sorts by |
|---|---|
| PostgreSQL | **alias** (`t.b`) 📄🧪 |
| MySQL | **alias** 📄🧪 |
| SQLite | **alias** 📄🧪 |
| DuckDB | **alias** 🧪 |
| Databricks | **alias** 📄 ("ORDER BY prefers the SELECT list alias over the table column") |
| BigQuery | **alias** 📄 (SELECT aliases "override names in the corresponding FROM clause") |
| ClickHouse | **alias** by default 📄 (`prefer_column_name_to_alias = 0`) |
| Trino, Snowflake | ❔ not documented |

Postgres documents this as the opposite of its GROUP BY rule, done "to be compatible with the SQL standard".

Things that do **not** follow alias-first:

- **A qualified name.** `ORDER BY t.a` is always the input column 🧪 (all four engines).
- **A name inside an expression.**
  - When the name collides, the input column wins: `SELECT b AS a FROM t ORDER BY a + 0` sorts by `t.a` 🧪 (all four engines).
  - When it doesn't collide, Postgres rejects the alias in an expression: `SELECT b AS x FROM t ORDER BY x + 0` fails with `column "x" does not exist`. The docs say "an output column name has to stand alone" 📄🧪.
  - MySQL, SQLite and DuckDB accept that last query and resolve `x` to the alias 🧪.

### GROUP BY: input column first, alias as fallback (mostly)

| Dialect | `SELECT c AS a, COUNT(*) FROM t GROUP BY a` groups by |
|---|---|
| PostgreSQL | **input column** `t.a` 📄🧪. Then `c` is ungrouped, so the query errors. |
| MySQL | **input column** 📄🧪. Raises warning 1052 `Column 'a' in group statement is ambiguous`. Errors under `ONLY_FULL_GROUP_BY`. |
| SQLite | **input column** 🧪. Returns 3 groups. Note: reading the order of SQLite's documented rules suggests alias-first, but the engine does not behave that way. |
| DuckDB | **input column** 🧪 |
| Snowflake | **input column** 📄 ("the clause uses the column name") |
| Oracle 23ai | **input column** 📄 |
| Databricks | **input column**, inferred from a doc example, not stated in prose |
| BigQuery | **alias** 📄 |
| ClickHouse | **alias** by default 📄 (aliases are global; `prefer_column_name_to_alias = 0`) |
| Trino | n/a (aliases not documented in GROUP BY) |

Further rules:

- **When nothing collides, the alias is the fallback.** `GROUP BY x`, where `x` is only an alias, works in every engine that supports GROUP BY aliases 🧪.
- **An alias inside an expression** (`GROUP BY x + 0`):
  - Rejected by Postgres (`column "x" does not exist`) 🧪.
  - Rejected explicitly by DuckDB ("aliases cannot be used as part of an expression in the GROUP BY") 🧪.
  - Accepted by MySQL and SQLite 🧪.
- **An alias of an aggregate** (`SELECT SUM(b) AS total FROM t GROUP BY total`) is rejected by **all four tested engines**, MySQL included (error 1056 `Can't group on 'total'`) 🧪.

### HAVING: depends heavily on the dialect

| Dialect | `SELECT c, COUNT(*) AS a FROM t GROUP BY c HAVING a > 1` filters on |
|---|---|
| PostgreSQL | n/a: aliases are not allowed in HAVING 📄. The name resolves to `t.a`, which is ungrouped, so the query errors 🧪. |
| MySQL | **alias** 🧪 (see the MySQL note below) |
| SQLite | **input column** 🧪 |
| DuckDB | **input column** 🧪 (then errors, because `t.a` is ungrouped) |
| Databricks | **input column** 📄 ("HAVING prefers the table column over the SELECT list alias") |
| BigQuery | **alias** 📄 |
| ClickHouse | **alias** by default 📄 |
| Trino, Snowflake | ❔ |

**MySQL in HAVING.** The MySQL docs say "For GROUP BY or HAVING clauses, it searches the FROM clause before searching in the select_expr values" 📄. That is not what MySQL 9.2 does when the FROM column is not grouped. The observed order 🧪 is:

1. a GROUP BY column. 📄 "if a HAVING column name is used both in GROUP BY and as an aliased column in the select column list, preference is given to the column in the GROUP BY column". 🧪 `SELECT c, COUNT(*) AS c ... GROUP BY c HAVING c > 1` filters on the column and raises warning 1052.
2. then a SELECT alias. 🧪 The H2 query above uses `COUNT(*)`, not the ungrouped `t.a`.
3. then any other input column.

### Duplicate aliases

`SELECT a AS x, b AS x FROM t ORDER BY x`:

| Dialect | Behaviour |
|---|---|
| PostgreSQL | error: `ORDER BY "x" is ambiguous` 🧪 |
| MySQL | error 1052: `Column 'x' in order clause is ambiguous` 🧪 |
| SQLite | silently uses the **first** `x` 🧪 |
| DuckDB | silently uses the **last** `x` 🧪 |

### Contexts with no input-column fallback

- **After a set operation.** ORDER BY following `UNION` / `INTERSECT` / `EXCEPT` sees only the output names, which come from the first branch, and ordinals.
  - `SELECT a FROM t UNION ALL SELECT b FROM t ORDER BY b` errors in Postgres and MySQL 🧪.
  - SQLite and DuckDB accept it 🧪.
  - SQL Server documents the same restriction 📄.
- **`SELECT DISTINCT`.** Postgres and MySQL require ORDER BY expressions to appear in the select list 🧪. `SELECT DISTINCT b FROM t ORDER BY a` errors in both. SQLite and DuckDB accept it.

## How they appear in the sqlparser AST

In sqlparser 0.60.0, back-references aren't a distinct AST node. They look exactly like regular expressions.

**Positional**: `Expr::Value(Value::Number(...))`.
```rust
// "ORDER BY 1"
OrderByExpr {
    expr: Expr::Value(Value::Number("1", false).with_empty_span()),
    ..
}
```

**Alias**: `Expr::Identifier(Ident { value: "total", .. })`. It can't be told apart from a column reference until lookup.

A **qualified** name (`Expr::CompoundIdentifier`) is never a back-reference.

## Current behavior

`resolve_expr` is called on the bare expression in each clause:

- `src/resolve/query.rs:116`: `ORDER BY` via `resolve_order_by`.
- `src/resolve/select.rs:124`: `GROUP BY` via `resolve_group_by`.
- `src/resolve/select.rs:127-132`: `HAVING`, inline.

`resolve_expr` resolves identifiers only against the scope's **sources**. It never consults `selected_columns`.

| Form | What happens | Lineage effect |
|---|---|---|
| `ORDER BY 1` / `GROUP BY 1` | `Expr::Value` hits the no-op arm (`src/resolve/expr.rs:223`) | Silently dropped: no sort or group dependency recorded |
| `ORDER BY total` / `GROUP BY total` / `HAVING total > 100` (no such input column) | `resolve_col` → `ColumnNotFound` | Hard error on queries engines accept |
| `SELECT b AS a FROM t ORDER BY a` (`t.a` exists) | Resolves to `t.a` | **Wrong dependency**: every tested engine sorts by `t.b` |
| `SELECT c AS a ... GROUP BY a` (`t.a` exists) | Resolves to `t.a` | Correct for Postgres, MySQL, SQLite, DuckDB, Snowflake, Oracle; wrong for BigQuery and ClickHouse |
| `... HAVING a > 1` where `a` is both an alias and an ungrouped `t.a` | Resolves to `t.a` | Wrong for MySQL; correct for Databricks, SQLite, DuckDB |
| ORDER BY on a set operation | Each branch is resolved in its own scope (`resolve_select(_, true)` → `branch_scope`), so the query scope has no `sources` and no `selected_columns` | Any named ORDER BY on a `UNION` fails with `ColumnNotFound` |

Every one of these failures is wrong for lineage:
- A positional reference silently under-reports dependencies.
- An alias reference either breaks resolution or binds to the wrong column.

## Fix design

### Where back-references can occur

By the time GROUP BY, HAVING and ORDER BY are resolved, the projection has already run, so the scope's `selected_columns: Vec<SelectedColumn>` is fully populated for a plain SELECT. Each `SelectedColumn` carries its output `name` and its underlying `dependencies: HashSet<ColumnRef>`.

The exception is **set operations**. There, the outer ORDER BY must read the `selected_columns` of the **first branch's** scope, because the query scope itself has none.

The fix is a back-reference lookup that substitutes a SELECT item's `dependencies` into the active accumulator. **The lookup order is a property of the clause**, not one global rule.

### Resolution rules

A back-reference resolves only against the `selected_columns` of the current SELECT. It never crosses scope boundaries.

**Positional (`Expr::Value(Value::Number(n, _))`, top level only):**
1. Parse `n` as a 1-based index.
2. If `n < 1` or `n > selected_columns.len()`, return `InvalidPositionalReference`.
3. Otherwise, extend the accumulator with `selected_columns[n-1].dependencies` and stop walking.

**Qualified name (`Expr::CompoundIdentifier`):** always resolve against sources. Never consult aliases.

**Bare name (`Expr::Identifier`), by clause:**

| Clause | Lookup order | Matches |
|---|---|---|
| `ORDER BY`, top-level bare name | **select list → sources** | Postgres, MySQL, SQLite, DuckDB, Databricks, BigQuery, ClickHouse |
| `ORDER BY`, name inside an expression | **sources → select list** (alias only on a miss) | MySQL, SQLite, DuckDB (Postgres rejects the miss case, which is fine for lineage) |
| `ORDER BY` after a set operation | **first branch's select list only** | Postgres, MySQL, SQL Server |
| `GROUP BY` | **sources → select list** | Postgres, MySQL, SQLite, DuckDB, Snowflake, Oracle, Databricks |
| `HAVING` | **GROUP BY columns → select list → sources** (MySQL) | MySQL 🧪 |

Dialect switches to add when they become needed:
- **BigQuery and ClickHouse:** the select list comes first in GROUP BY and HAVING.
- **Databricks, SQLite and DuckDB:** sources come first in HAVING.

Expose these as a per-dialect option on `ResolutionOptions`. Default to MySQL, since that is the target input.

**Ambiguity:** if more than one `selected_columns` entry matches the name, return `AmbiguousAlias`. This mirrors Postgres and MySQL, which both error. SQLite and DuckDB silently pick different items, so there is no single "lenient" answer to copy.

### Where it plugs in

| Clause | Site | Treatment |
|---|---|---|
| `GROUP BY` | `resolve_group_by` (`select.rs`) | Positional check at the top level. Bare names resolve sources-first with alias fallback. |
| `HAVING` | HAVING block in `resolve_select` (`select.rs:127`) | Aliases appear nested (`HAVING total > 100` is a `BinaryOp`), so substitution must happen inside `resolve_expr` when it reaches a bare identifier. A top-level-only check does **not** cover the common case. |
| `ORDER BY` | `resolve_order_by` (`query.rs:116`) | Positional and bare-name alias-first at the top level. Nested names are sources-first with alias fallback. For set operations, look up the first branch's scope. |

Cleanest design: give `resolve_expr` / `resolve_col` an optional **alias-lookup mode** that the caller sets per clause: `None`, `AliasFirst` or `AliasOnMiss`. Positional references are top-level only, so they stay at the clause level.

### Restricted scope vs full power

A top-level-only first cut covers `GROUP BY 1`, `GROUP BY total`, `ORDER BY 1` and `ORDER BY total`. It does **not** cover `HAVING total > 100`, because there the alias sits inside a comparison. HAVING aliases therefore need the nested lookup from day one, or need to be explicitly deferred.

Recommended order:
1. Positional references, plus top-level ORDER BY and GROUP BY names, with the per-clause order above. This fixes the silent drop and the wrong ORDER BY dependency.
2. Nested lookup mode in `resolve_expr` for HAVING and for expressions in ORDER BY and GROUP BY.
3. ORDER BY over set operations (first-branch lookup).
4. Dialect switches.

## Edge cases & non-goals

- **Aggregate aliases in GROUP BY.** `GROUP BY total`, where `total = SUM(amount)`, is rejected by every engine tested, MySQL included (`Can't group on 'total'`). We don't validate this; we just substitute the dependencies.
- **Self-referencing aliases.**
  - `SELECT -a AS a FROM t ORDER BY a` sorts by the **output expression** `-a` in all four tested engines 🧪. The lineage is `t.a` either way, but the resolver should still take the alias path so the rules stay consistent.
  - `ORDER BY a + 0` in the same query uses the **input** `t.a` 🧪.
- **`SELECT DISTINCT` and set-operation restrictions** (ORDER BY items must be output columns): not validated. For lineage, we resolve the ORDER BY dependencies the same way either way.
- **Out of scope:** checking that HAVING column references are grouped or aggregated. This is an existing non-goal; see `docs/analysis.md` §3.

## Verification

End-to-end cases to add (under `tests/fixtures/queries/edge_cases/` or `tests/fixtures/queries/scope_tree/`), assuming `t(a, b, c)` and the MySQL default:

```sql
-- positional
SELECT user_id, SUM(amount) FROM orders GROUP BY 1 ORDER BY 2 DESC;
-- group_by = {user_id}, sort = {amount}

-- alias, top-level
SELECT user_id, SUM(amount) AS total FROM orders GROUP BY user_id ORDER BY total DESC;
-- sort = {amount}

-- alias, nested in HAVING (needs nested lookup)
SELECT user_id, SUM(amount) AS total FROM orders GROUP BY user_id HAVING total > 100;
-- filter = {amount}

-- ORDER BY: alias beats column
SELECT b AS a FROM t ORDER BY a;          -- sort = {t.b}
SELECT b AS a FROM t ORDER BY t.a;        -- sort = {t.a}  (qualified)
SELECT b AS a FROM t ORDER BY a + 0;      -- sort = {t.a}  (inside expression, column wins)
SELECT b FROM t ORDER BY a;               -- sort = {t.a}  (no alias, falls back to source)

-- GROUP BY: column beats alias
SELECT c AS a, COUNT(*) FROM t GROUP BY a;   -- group_by = {t.a}
SELECT c AS x, COUNT(*) FROM t GROUP BY x;   -- group_by = {t.c}  (alias fallback)

-- HAVING (MySQL): alias beats ungrouped column, GROUP BY column beats alias
SELECT c, COUNT(*) AS a FROM t GROUP BY c HAVING a > 1;   -- filter = {} (COUNT(*) has no column deps)
SELECT c, COUNT(a) AS c FROM t GROUP BY c HAVING c > 1;   -- filter = {t.c}

-- set operation
SELECT a FROM t UNION ALL SELECT b FROM t ORDER BY a;     -- sort resolves via first branch's `a`
SELECT a FROM t UNION ALL SELECT b FROM t ORDER BY b;     -- error (no such output column)

-- ambiguity guard
SELECT a AS x, b AS x FROM t ORDER BY x;  -- error: AmbiguousAlias

-- out-of-range positional
SELECT a FROM t ORDER BY 5;               -- error: InvalidPositionalReference
```

Each case should snapshot the resulting `group_by_columns` / `filter_columns` / `sort_columns` / `selected_columns[*].dependencies` sets.

## Summary of work

1. Add `InvalidPositionalReference` and `AmbiguousAlias` to `ResolutionError`.
2. Add a clause-level alias-lookup mode (`None` / `AliasFirst` / `AliasOnMiss`) to `resolve_expr` / `resolve_col`.
3. `resolve_order_by`: positional, top-level `AliasFirst`, nested `AliasOnMiss`. Use the first branch's scope for set operations.
4. `resolve_group_by`: positional, `AliasOnMiss`.
5. HAVING block: the MySQL order (GROUP BY column → alias → source).
6. Later: dialect switches on `ResolutionOptions` for BigQuery, ClickHouse, Databricks, SQLite and DuckDB.
7. Add the test queries above and snapshot the lineage output.

## Empirical results

Table `t(a, b, c) = (1,30,1), (2,20,1), (3,10,2)`.
- Sorting by `t.a` gives the `b` column as `30,20,10`.
- Sorting by `b` gives `10,20,30`.

| # | Query | PostgreSQL 14.17 | MySQL 9.2.0 | SQLite 3.54.0 | DuckDB 1.1.3 |
|---|---|---|---|---|---|
| O1 | `SELECT b AS a FROM t ORDER BY a` | 10,20,30 (alias) | 10,20,30 (alias) | 10,20,30 (alias) | 10,20,30 (alias) |
| O2 | `SELECT b FROM t ORDER BY a` | 30,20,10 | 30,20,10 | 30,20,10 | 30,20,10 |
| O3 | `SELECT b AS a FROM t ORDER BY t.a` | 30,20,10 (column) | 30,20,10 | 30,20,10 | 30,20,10 |
| O4 | `SELECT b AS a FROM t ORDER BY a + 0` | 30,20,10 (column) | 30,20,10 (column) | 30,20,10 (column) | 30,20,10 (column) |
| O5 | `SELECT b AS x FROM t ORDER BY x + 0` | error: column "x" does not exist | 10,20,30 | 10,20,30 | 10,20,30 |
| O6 | `SELECT -a AS a FROM t ORDER BY a` | -3,-2,-1 (alias) | -3,-2,-1 (alias) | -3,-2,-1 (alias) | -3,-2,-1 (alias) |
| O7 | `SELECT a AS x, b AS x FROM t ORDER BY x` | error: ambiguous | error 1052: ambiguous | uses first `x` | uses last `x` |
| O8 | `SELECT DISTINCT b FROM t ORDER BY a` | error | error 3065 | OK | OK |
| O9 | `SELECT a FROM t UNION ALL SELECT b FROM t ORDER BY a` | OK | OK | OK | OK |
| O10 | `... UNION ALL ... ORDER BY b` | error: column "b" does not exist | error 1054 | OK | OK |
| O11 | `SELECT a, b FROM t ORDER BY 2` | OK | OK | OK | OK |
| G1 | `SELECT c AS a, COUNT(*) FROM t GROUP BY a` | error: t.c not grouped (→ column) | error 1055 (→ column; warning 1052) | 3 groups (→ column) | error: c not grouped (→ column) |
| G2 | `SELECT c AS x, COUNT(*) FROM t GROUP BY x` | OK (alias) | OK | OK | OK |
| G3 | `SELECT c, COUNT(*) FROM t GROUP BY 1` | OK | OK | OK | OK |
| G4 | `SELECT SUM(b) AS total FROM t GROUP BY total` | error | error 1056 Can't group on 'total' | error | error |
| G5 | `SELECT c AS x, COUNT(*) FROM t GROUP BY x + 0` | error: column "x" does not exist | resolves alias | OK | error: aliases not allowed in GROUP BY expressions |
| H1 | `SELECT c, COUNT(*) AS n FROM t GROUP BY c HAVING n > 1` | error: column "n" does not exist | (1,2) | (1,2) | (1,2) |
| H2 | `SELECT c, COUNT(*) AS a FROM t GROUP BY c HAVING a > 1` | error: t.a not grouped (→ column) | (1,2) (→ alias) | (2,1) (→ column) | error: a not grouped (→ column) |
| H3 | `SELECT c, COUNT(*) AS c FROM t GROUP BY c HAVING c > 1` | — | (2,1) (→ GROUP BY column; warning 1052) | — | — |

G5 on MySQL errors with 1055 (`c` is not functionally dependent on `c + 0`). The error message shows `x` was resolved to the alias rather than reported as unknown.

## Sources

- PostgreSQL, SELECT: <https://www.postgresql.org/docs/current/sql-select.html>
  - "If an ORDER BY expression is a simple name that matches both an output column name and an input column name, ORDER BY will interpret it as the output column name. This is the opposite of the choice that GROUP BY will make in the same situation."
  - "In case of ambiguity, a GROUP BY name will be interpreted as an input-column name rather than an output column name."
  - "An output column's name can be used to refer to the column's value in ORDER BY and GROUP BY clauses, but not in the WHERE or HAVING clauses"
  - Compatibility section: "In the SQL-92 standard, an ORDER BY clause can only use output column names or numbers, while a GROUP BY clause can only use expressions based on input column names."
- PostgreSQL, Sorting rows: <https://www.postgresql.org/docs/current/queries-order.html>
  - "an output column name has to stand alone, that is, it cannot be used in an expression"
- MySQL 8.4, SELECT: <https://dev.mysql.com/doc/refman/8.4/en/select.html>
  - "MySQL resolves unqualified column or alias references in ORDER BY clauses by searching in the select_expr values, then in the columns of the tables in the FROM clause. For GROUP BY or HAVING clauses, it searches the FROM clause before searching in the select_expr values."
  - "if a HAVING column name is used both in GROUP BY and as an aliased column in the select column list, preference is given to the column in the GROUP BY column."
  - "Use of column positions is deprecated because the syntax has been removed from the SQL standard."
- MySQL error reference (1056 `ER_WRONG_GROUP_FIELD`): <https://dev.mysql.com/doc/mysql-errors/8.0/en/server-error-reference.html>
- Trino, SELECT: <https://trino.io/docs/current/sql/select.html>
  - GROUP BY "may contain any expression composed of input columns or it may be an ordinal number selecting an output column by position"
  - ORDER BY: "Each expression may be composed of output columns, or it may be an ordinal number"
- Spark configuration (`spark.sql.groupByAliases`, `spark.sql.groupByOrdinal`, `spark.sql.orderByOrdinal`, all default `true`): <https://spark.apache.org/docs/latest/configuration.html>
- Databricks, name resolution: <https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-name-resolution>
  - "ORDER BY prefers the SELECT list alias over the table column."
  - "HAVING prefers the table column over the SELECT list alias."
- BigQuery, query syntax: <https://cloud.google.com/bigquery/docs/reference/standard-sql/query-syntax>
  - "If a query contains aliases in the SELECT clause, those aliases override names in the corresponding FROM clause."
- Snowflake, GROUP BY: <https://docs.snowflake.com/en/sql-reference/constructs/group-by>
  - "If a clause contains a name that matches both a column name and an alias, then the clause uses the column name."
- Snowflake, HAVING: <https://docs.snowflake.com/en/sql-reference/constructs/having>
- Snowflake, ORDER BY: <https://docs.snowflake.com/en/sql-reference/constructs/order-by>
- Oracle 23, SELECT: <https://docs.oracle.com/en/database/oracle/oracle-database/23/sqlrf/SELECT.html>
  - "From Release 23 you can use c_alias in group_by_clause."
  - "If a column name in the source tables and column alias in the SELECT list are the same, GROUP BY will interpret the identifier as the column name, not the alias."
  - `group_by_position_enabled` is false by default.
- SQL Server, GROUP BY: <https://learn.microsoft.com/en-us/sql/t-sql/queries/select-group-by-transact-sql>
  - "A GROUP BY column expression can't contain a column alias that you define in the SELECT list."
- SQL Server, ORDER BY: <https://learn.microsoft.com/en-us/sql/t-sql/queries/select-order-by-clause-transact-sql>
- ClickHouse, syntax (aliases are global): <https://clickhouse.com/docs/sql-reference/syntax>
- ClickHouse, `prefer_column_name_to_alias` and `enable_positional_arguments`: <https://clickhouse.com/docs/operations/settings/settings> (also in `src/Core/Settings.cpp`)
- DuckDB, friendly SQL ("Column aliases in WHERE, GROUP BY, and HAVING"): <https://duckdb.org/docs/stable/sql/dialect/friendly_sql>
- Redshift, GROUP BY (ordinals): <https://docs.aws.amazon.com/redshift/latest/dg/r_GROUP_BY_clause.html>
- SQLite, SELECT (ORDER BY / GROUP BY term resolution): <https://www.sqlite.org/lang_select.html>
