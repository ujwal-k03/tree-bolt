# SELECT-list back-references in GROUP BY / HAVING / ORDER BY

Spec for resolving positional and alias references back into the SELECT list. Covers what the forms are, what dialects allow them, how they appear in the sqlparser AST, what the resolver does today, and the plan to fix the gap.

## What is a "back-reference"?

A clause that runs *after* the SELECT list is named (positionally or by alias) can refer to a SELECT item instead of repeating its expression. Two surface forms:

**Positional** — refer to a SELECT item by 1-based index.
```sql
SELECT user_id, SUM(amount) AS total
FROM orders
GROUP BY 1               -- == GROUP BY user_id
ORDER BY 2 DESC;         -- == ORDER BY SUM(amount) DESC
```

**Alias** — refer to a SELECT item by its output name.
```sql
SELECT user_id, SUM(amount) AS total
FROM orders
GROUP BY user_id
HAVING total > 100       -- == HAVING SUM(amount) > 100
ORDER BY total DESC;     -- == ORDER BY SUM(amount) DESC
```

Both forms are pure syntactic sugar — the engine resolves them at bind time to the underlying expression. From a lineage standpoint they should produce the **same dep set** as the de-sugared form.

## Dialect support matrix

| Dialect | ORDER BY alias | ORDER BY pos. | GROUP BY alias | GROUP BY pos. | HAVING alias |
|---|---|---|---|---|---|
| Standard SQL (SQL:2016) | ✅ | ✅ (deprecated) | ❌ | ❌ | ❌ |
| PostgreSQL | ✅ | ✅ | ✅ | ✅ | ✅ |
| MySQL | ✅ | ✅ | ✅ | ✅ | ✅ |
| SQLite | ✅ | ✅ | ✅ | ✅ | ✅ |
| BigQuery | ✅ | ✅ | ✅ | ✅ | ✅ |
| Snowflake | ✅ | ✅ | ✅ | ✅ | ✅ |
| Redshift | ✅ | ✅ | ✅ | ✅ | ✅ |
| DuckDB | ✅ | ✅ | ✅ | ✅ | ✅ |
| ClickHouse | ✅ | ✅ | ✅ | ✅ | ✅ |
| SQL Server | ✅ | ✅ | ❌ | ❌ | ❌ |
| Oracle | ✅ | ✅ | ❌ | ❌ | ❌ |

**Takeaways:**
- ORDER BY back-refs (both forms) are effectively universal.
- GROUP BY / HAVING back-refs work in every mainstream analytics/OLTP engine *except* Oracle and SQL Server.
- This resolver targets MySQL-shaped input (see `tests/fixtures/queries/`), so all three clauses need support.

## How they appear in the sqlparser AST

In sqlparser 0.60.0, back-references aren't a distinct AST node — they look exactly like regular expressions. The resolver only learns it's a back-reference by *failing* to resolve it as a column.

**Positional** — `Expr::Value(Value::Number(...))`:
```rust
// "ORDER BY 1"
OrderByExpr {
    expr: Expr::Value(Value::Number("1", false).with_empty_span()),
    ..
}
```

**Alias** — `Expr::Identifier(Ident { value: "total", .. })`. Indistinguishable from a column reference until lookup.

## Current behavior

`resolve_expr` is called on the bare expression in each clause:

- `src/resolve/query.rs:116` — `ORDER BY` via `resolve_order_by`.
- `src/resolve/select.rs:124` — `GROUP BY` via `resolve_group_by`.
- `src/resolve/select.rs:127-132` — `HAVING` inline.

What happens for each form today:

| Form | What `resolve_expr` does | Lineage effect |
|---|---|---|
| `ORDER BY 1` | `Expr::Value` falls into the no-op arm | Silently dropped — no sort dep recorded |
| `GROUP BY 1` | Same | Silently dropped — no group dep recorded |
| `ORDER BY total` | Treated as `Expr::Identifier("total")` → `resolve_col` searches sources → `ColumnNotFound` | Hard error |
| `GROUP BY total` | Same | Hard error |
| `HAVING total > 100` | `Expr::Identifier("total")` inside a BinaryOp → same path → `ColumnNotFound` | Hard error |

Both failure modes are wrong for lineage. Positional silently under-reports deps; alias breaks resolution of queries that engines accept.

## Fix design

### Where back-references can occur

By the time GROUP BY, HAVING, and ORDER BY are resolved, projection has already run — so the active scope's `selected_columns: Vec<SelectedColumn>` is fully populated. Each `SelectedColumn` carries the output `name` and the underlying `dependencies: HashSet<ColumnRef>`.

The fix is a back-reference lookup that runs *before* the normal expression walk, and substitutes the SELECT item's `dependencies` into the active accumulator.

### Resolution rules

A back-reference resolves against the active scope's `selected_columns` only. It never crosses scope boundaries.

**Positional (`Expr::Value(Value::Number(n, _))`):**
1. Parse `n` as a 1-based index.
2. If `n < 1` or `n > selected_columns.len()` → `InvalidPositionalReference`.
3. Otherwise, extend the active accumulator with `selected_columns[n-1].dependencies` and stop walking the expression.

**Alias (`Expr::Identifier(ident)`):**
1. Try column resolution against scope sources first (`resolve_col`).
2. **If** that returns `ColumnNotFound` **and** the identifier matches a `selected_columns[i].name`, fall back: extend the accumulator with `selected_columns[i].dependencies` and succeed.
3. Why column-first: in `SELECT a AS b FROM t GROUP BY a`, both interpretations exist but the column ref is the standards-compliant one. Falling back to alias only on miss preserves correct behavior for unambiguous cases and follows what Postgres documents (alias resolution is a "last-resort" fallback).
4. Ambiguity — if two SELECT items share the same alias, sqlparser will still parse it; flag as `AmbiguousAlias` to mirror engine behavior (Postgres errors, MySQL silently picks one — we err on the strict side).

### Where it plugs in

Three call sites. All three already use the accumulator pattern, so the back-reference lookup just becomes an alternative way of populating the accumulator before / instead of `resolve_expr`.

| Clause | Site | Treatment |
|---|---|---|
| `GROUP BY` | `resolve_group_by` (`select.rs`) | Check each top-level expr in `GroupByExpr::Expressions` for positional/alias; fall back to `resolve_expr` otherwise. |
| `HAVING` | `resolve_select` HAVING block (`select.rs:127`) | Aliases only — positional `HAVING 1` isn't a thing in any dialect. Aliases can be nested arbitrarily deep (`HAVING total > 100`), so the substitution has to happen inside `resolve_expr` when it encounters a bare identifier, not at the top level. |
| `ORDER BY` | `resolve_order_by` (`query.rs:116`) | Check each `OrderByExpr.expr` for positional/alias; fall back to `resolve_expr`. Sub-expression aliases (`ORDER BY total + 1`) need the same nested-identifier handling as HAVING. |

The HAVING and "nested" case point at the cleanest design: **extend `resolve_col` (or its caller in `resolve_expr`) with an optional "consult SELECT aliases on miss" flag, set by the caller per clause.** Positional refs are top-level only in practice, so those stay handled at the clause level.

### Restricted scope vs full power

A minimal first cut: handle only the **top-level** back-reference form (`GROUP BY 1`, `GROUP BY total`, `ORDER BY 1`, `ORDER BY total`, `HAVING total > 100` where `total` is the *whole* HAVING expression). This covers the common case and lands without touching `resolve_expr`.

A complete fix handles nested aliases (`HAVING total > 100`, `ORDER BY total + 1`, `GROUP BY total + offset`). This requires alias substitution inside `resolve_expr` — a per-call flag, threaded through.

Recommend **shipping the minimal cut first**, since it handles the queries we've seen, and tracking the nested form as a follow-up.

## Edge cases & non-goals

- **Aggregates in GROUP BY back-references** — `GROUP BY total` where `total = SUM(amount)` is *legal in MySQL but illegal in standard SQL and Postgres* (you can't group by an aggregate). We don't validate; we just substitute the deps. Same philosophy as the existing HAVING legality note (`docs/analysis.md` §3).
- **Recursive aliases** — `SELECT a + 1 AS a FROM t ORDER BY a` is ambiguous: does `a` mean the input column or the output expression? Engines differ. Resolver chooses the column-first rule above, which matches Postgres.
- **CTEs and set ops** — back-references are scoped to the current SELECT. Set-op branches (UNION arms) each have their own SELECT list; ORDER BY on a UNION uses the *first* arm's output names per standard SQL. We don't need to do anything special — by the time we resolve the outer ORDER BY, the relevant scope's `selected_columns` is already what we want.
- **Out of scope:** validating that HAVING column refs are grouped-or-aggregated (existing non-goal — see `docs/analysis.md` §3).

## Verification

End-to-end test cases to add (under `tests/fixtures/queries/edge_cases/` or `tests/fixtures/queries/scope_tree/`):

```sql
-- positional
SELECT user_id, SUM(amount) FROM orders GROUP BY 1 ORDER BY 2 DESC;

-- alias, top-level
SELECT user_id, SUM(amount) AS total FROM orders GROUP BY user_id HAVING total > 100 ORDER BY total DESC;

-- alias, nested (gated on the nested fix)
SELECT user_id, SUM(amount) AS total FROM orders GROUP BY user_id HAVING total + 1 > 100;

-- ambiguity guard
SELECT a AS x, b AS x FROM t ORDER BY x;  -- should error: AmbiguousAlias

-- out-of-range positional
SELECT a FROM t ORDER BY 5;  -- should error: InvalidPositionalReference

-- alias vs column collision (column wins)
SELECT a + 1 AS a FROM t ORDER BY a;  -- ORDER BY resolves to base column t.a, not the expr
```

Each should snapshot the resulting `group_by_columns` / `filter_columns` / `sort_columns` / `selected_columns[*].dependencies` sets.

## Summary of work

1. Add `InvalidPositionalReference` and `AmbiguousAlias` to `ResolutionError`.
2. In `resolve_group_by`: before `resolve_expr`, detect `Expr::Value(Number)` and `Expr::Identifier` against `selected_columns`.
3. In `resolve_order_by`: same handling on `order_by_expr.expr`.
4. In the HAVING block of `resolve_select`: alias lookup for top-level `Expr::Identifier`.
5. (Follow-up) Thread a "consult aliases on miss" flag through `resolve_expr` / `resolve_col` for nested alias support.
6. Add the test queries above and snapshot lineage output.