# TreeBolt

**TreeBolt** is a Rust library for **name resolution and scope analysis** over a SQL AST. It takes a `sqlparser` AST plus a user-supplied schema and produces a tree of resolved scopes — each one knowing its sources, its selected columns with per-column dependency sets, and its role-tagged column usages (join / filter / group / sort).

It is the foundation layer for column-level lineage. Lineage extraction itself is a downstream module that consumes these resolved scopes (currently a stub — see [`src/lineage/`](src/lineage)).

## Status

Early / pre-1.0. The resolver covers the common shape of analytical `SELECT` queries (CTEs, subqueries, joins, set ops, window functions, lateral derived tables) but does not yet handle DML, every exotic `TableFactor`, or every corner of expression syntax. See [Supported / Unsupported](#supported--unsupported).

## How it works

1. You parse a SQL string with [`sqlparser`](https://docs.rs/sqlparser) and hand the resulting `Statement` to `Resolver::resolve`.
2. The resolver walks the AST, opening a new scope at every nested query, derived table, CTE, and set-op branch.
3. For each column reference it consults a `SchemaProvider` to verify the source/column exists, then records the resolved `ColumnRef` against the scope it was used in — tagged by role (selected, join, filter, group-by, sort).
4. The result is a `Vec<ResolvedScope>` — a flat arena with parent/child links — serializable to JSON for downstream consumers.

## Schema providers

Schemas are pulled through the `SchemaProvider` trait:

```rust
pub trait SchemaProvider {
    fn get_schema(&self, ident: &Vec<String>) -> Option<TableSchema>;
}
```

`ident` is the parts of a multi-part table name (e.g. `["platinum", "order_master_bi"]` for `platinum.order_master_bi`). Implement this against whatever your source of truth is — a metastore, an information_schema query, a static config, etc.

A `CsvSchemaProvider` is bundled (see `src/schema/provider.rs`) which reads one CSV per table from a directory. It's intended as a convenience for tests and demos — not a recommendation for how to ship schemas in production.

## Quick start

```rust
use sqlparser::dialect::GenericDialect;
use sqlparser::parser::Parser;
use treebolt::resolve::{Resolver, ResolutionOptions};
use treebolt::schema::provider::CsvSchemaProvider;

let sql = "SELECT o.id FROM platinum.order_master_bi o WHERE o.status = 'SHIPPED'";
let mut stmts = Parser::parse_sql(&GenericDialect {}, sql)?;

let schema = CsvSchemaProvider::new("src/schema/data")?;
let resolver = Resolver::new(schema, ResolutionOptions {
    expand_select_wildcards: false,
    qualify: false,
});

let scopes = resolver.resolve(&mut stmts[0])?;
println!("{}", serde_json::to_string_pretty(&scopes)?);
```

`scopes[0]` is the root scope; nested scopes are reachable via `children` ids and `parent` back-links.

Or just run the binary entry point, which resolves `docs/test_queries/query1.sql` against the bundled CSV schemas and writes the result to `src/resolution_results.json`:

```bash
cargo run
```

## Supported / Unsupported

### Supported

**Statements**
- `SELECT` queries (`Statement::Query`)

**Query structure**
- CTEs (`WITH`), including multiple CTEs
- Subqueries in `SELECT`, `WHERE`, `HAVING`, `ON`, set-op branches
- Derived tables (parenthesised query in `FROM`)
- `LATERAL` derived tables — outer-FROM sources made visible inward
- Correlation through arbitrary subquery depth (parent and transitive grandparent visibility)
- Set operations: `UNION` / `INTERSECT` / `EXCEPT`, each branch in its own scope

**FROM-clause table factors**
- Base tables (resolved through `SchemaProvider`)
- Derived tables
- CTE references
- Table functions (`TableFactor::TableFunction`, `TableFactor::Function`)
- `UNNEST`
- `PIVOT` / `UNPIVOT` (inner table + pivot exprs)

**Expressions & projection**
- Qualified and unqualified column refs (`a.b`, `b`) with ambiguity detection
- Wildcards: `*`, `t.*` (resolved against visible sources)
- Window functions — `OVER (PARTITION BY ... ORDER BY ...)` clauses are walked and contribute to column dependencies
- `GROUP BY` expressions
- `JOIN ... ON` — populates `join_columns`
- Per-column dependency sets propagated through subquery boundaries (an outer column's lineage is the union of every base column touched while resolving it)
- Role tagging on each scope: `selected_columns`, `join_columns`, `filter_columns`, `group_by_columns`, `sort_columns`

**Design**
- Pluggable schema via the `SchemaProvider` trait
- Serde-serializable scope tree (`ResolvedScope` → JSON)

### Unsupported / not yet wired up

**Statements** (returns `UnsupportedQueryType`)
- `INSERT`, `UPDATE`, `DELETE`, `MERGE`, and other non-`Query` statements

**FROM-clause table factors** (returns `UnsupportedTableFactor`)
- `MATCH_RECOGNIZE`
- `XMLTABLE`
- `JSON_TABLE` / `OPENJSON`
- `SEMANTIC_VIEW`

**Resolver gaps**
- SELECT-list back-references in `GROUP BY` / `HAVING` / `ORDER BY` — positional (`ORDER BY 1`) and alias (`ORDER BY total`) forms both fall through to a plain column lookup and currently error as `ColumnNotFound`
- `JOIN ... USING(...)` and `NATURAL JOIN` are parsed but do not populate `join_columns`
- A handful of `Expr` variants are no-ops in the expression walker if they appear in unusual positions: `Expr::Lambda`, `Expr::MatchAgainst`, `Expr::MemberOf`, `Expr::Dictionary`, `Expr::Map`, `Expr::Interval`
- `ResolutionOptions::expand_select_wildcards` and `ResolutionOptions::qualify` are accepted but not yet acted on — wildcards are always resolved in place and the AST is not rewritten

**Downstream**
- `src/lineage/` is a stub. The per-column dependency sets on `SelectedColumn` plus the role-tagged scope-level sets are the inputs it will consume.

See [`TODO.md`](TODO.md) for the live punch list.

## Project layout

```
src/
  resolve/         # scope walker — the bulk of the work
    scope/         # ResolvedScope, ColumnRef, ResolvedSource
    select.rs      # projection, GROUP BY, HAVING, ORDER BY
    from.rs        # table factors, joins
    expr.rs        # expression walker
    function.rs    # function calls, OVER clauses
    wildcard.rs    # * and t.*
    query.rs       # query / set-op / CTE entry
    column.rs      # column ref resolution against visible scopes
    errors.rs
  schema/
    mod.rs         # SchemaProvider trait, TableSchema
    provider.rs    # CsvSchemaProvider (demo impl)
    data/          # sample CSV schemas
  lineage/         # downstream lineage extraction (stub)
docs/
  analysis.md      # design notes
  test_queries/    # sample SQL used by the binary
```

## Contributing

Pick anything from [`TODO.md`](TODO.md). The resolver is structured so that each `TableFactor` / `Expr` arm lives in a small file under `src/resolve/` — adding support for a new construct is usually localised to one of those.

## License

TBD.