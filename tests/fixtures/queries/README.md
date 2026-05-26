# Sample queries

Each `.sql` file is one statement and the filename names what it exercises.
Use these as fixtures when working on the resolver or when adding tests.

## Layout

- `real_world/` - production-shaped queries with CTEs, joins, window funcs.
  Useful for stress-testing the resolver against realistic input.
- `scope_tree/` - minimal queries chosen to produce a specific scope shape
  (CTE + derived table + subquery + UNION, correlated subqueries, etc.).
- `cte/` - CTE-specific semantics: shadowing, visibility through derived
  tables, name collisions with base tables, nesting.
- `edge_cases/` - small one-liners that probe a single resolver concern
  (lambda args, qualified column refs, duplicate aliases, `SELECT *`, …).
- `unsupported/` - statements the resolver currently rejects on purpose
  (CTAS, `MATCH_RECOGNIZE`). Kept so we notice when support lands.
- `dialect_notes.md` - MySQL vs Trino divergences observed during design;
  not directly executable, but informs what semantics we choose.
