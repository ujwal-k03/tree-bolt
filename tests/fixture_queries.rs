//! Integration tests driven by the SQL fixtures under `tests/fixtures/queries/`.
//!
//! Each fixture is a real-shaped SQL snippet that exercises one resolver
//! concern (CTE shadowing, correlated subqueries, unsupported statements,
//! etc.). Tests provide a minimal stub schema covering only the tables a
//! given fixture references and assert either that resolution succeeds with
//! the expected scope shape or that it fails with the expected error category.

mod common;

use common::{load_fixture, resolve, InMemorySchema};

use treebolt::resolve::errors::ResolutionError;
use treebolt::resolve::scope::ScopeType;

// ---------- edge_cases ----------

#[test]
fn edge_count_aggregate_resolves() {
    let sql = load_fixture("tests/fixtures/queries/edge_cases/count_aggregate.sql");
    let schema = InMemorySchema::new(vec![("scrap.ujwal_t3", vec!["id"])]);

    let scopes = resolve(&sql, schema).expect("resolve count_aggregate");

    let root = &scopes[1];
    assert!(matches!(root.scope_type, ScopeType::Root));
    assert_eq!(root.sources.len(), 1, "expected one FROM source");
    assert_eq!(root.selected_columns.len(), 1, "COUNT(id) is one projection");
}

#[test]
fn edge_derived_table_dot_reference_resolves() {
    let sql = load_fixture("tests/fixtures/queries/edge_cases/derived_table_dot_reference.sql");
    let schema = InMemorySchema::new(vec![(
        "platinum.order_master_bi",
        vec!["order_date", "order_id"],
    )]);

    let scopes = resolve(&sql, schema).expect("resolve derived_table_dot_reference");

    // Root + DerivedTable scope at minimum.
    assert!(scopes.len() >= 3);
    let root = &scopes[1];
    assert!(root.sources.contains_key("T"), "derived table should expose alias `T`");
}

#[test]
fn edge_qualified_column_three_part_resolves() {
    let sql = load_fixture("tests/fixtures/queries/edge_cases/qualified_column_three_part.sql");
    let schema = InMemorySchema::new(vec![(
        "delta.platinum.order_master_bi",
        vec!["order_date"],
    )]);

    let scopes = resolve(&sql, schema).expect("resolve qualified_column_three_part");
    let root = &scopes[1];
    assert_eq!(root.selected_columns.len(), 1);
}

#[test]
fn edge_select_star_qualified_resolves() {
    let sql = load_fixture("tests/fixtures/queries/edge_cases/select_star_qualified.sql");
    let schema = InMemorySchema::new(vec![(
        "gold.order_master_bi",
        vec!["order_id", "order_date"],
    )]);

    let scopes = resolve(&sql, schema).expect("resolve select_star_qualified");
    let root = &scopes[1];
    assert_eq!(root.sources.len(), 1);
}

// ---------- cte ----------

#[test]
fn cte_visible_in_derived_table_resolves() {
    let sql = load_fixture("tests/fixtures/queries/cte/cte_visible_in_derived_table.sql");
    let schema = InMemorySchema::new(Vec::<(&'static str, Vec<&str>)>::new());

    resolve(&sql, schema).expect("resolve cte_visible_in_derived_table");
}

#[test]
fn cte_shadowed_in_derived_table_resolves() {
    let sql = load_fixture("tests/fixtures/queries/cte/cte_shadowed_in_derived_table.sql");
    let schema = InMemorySchema::new(Vec::<(&'static str, Vec<&str>)>::new());

    resolve(&sql, schema).expect("resolve cte_shadowed_in_derived_table");
}

#[test]
fn cte_inner_references_undefined_fails_with_table_not_found() {
    let sql = load_fixture("tests/fixtures/queries/cte/cte_inner_references_undefined.sql");
    let schema = InMemorySchema::new(Vec::<(&'static str, Vec<&str>)>::new());

    let err = match resolve(&sql, schema) {
        Ok(_) => panic!("expected resolution to fail — t3 is undefined"),
        Err(e) => e,
    };

    assert!(
        matches!(err, ResolutionError::TableNotFound(_)),
        "expected TableNotFound, got {err:?}"
    );
}

// ---------- scope_tree ----------

#[test]
fn scope_correlated_any_subquery_resolves() {
    let sql = load_fixture("tests/fixtures/queries/scope_tree/correlated_any_subquery.sql");
    let schema = InMemorySchema::new(vec![
        ("Table_1", vec!["column_1", "column_2"]),
        ("Table_2", vec!["column_1", "column_2"]),
    ]);

    let scopes = resolve(&sql, schema).expect("resolve correlated_any_subquery");

    // Root + Subquery scope at minimum.
    assert!(
        scopes.iter().any(|s| matches!(s.scope_type, ScopeType::Subquery)),
        "correlated subquery should produce a Subquery scope"
    );
}

#[test]
fn scope_cte_subquery_union_resolves() {
    let sql = load_fixture("tests/fixtures/queries/scope_tree/cte_subquery_union.sql");
    let schema = InMemorySchema::new(vec![
        ("users", vec!["id", "name"]),
        ("orders", vec!["id"]),
        ("logins", vec!["user_id"]),
        ("other_table", vec!["x"]),
    ]);

    let scopes = resolve(&sql, schema).expect("resolve cte_subquery_union");

    // Expect the scope tree to contain every flavor exercised by the fixture.
    let kinds: Vec<&ScopeType> = scopes.iter().map(|s| &s.scope_type).collect();
    assert!(kinds.iter().any(|k| matches!(k, ScopeType::Cte)), "missing Cte");
    assert!(kinds.iter().any(|k| matches!(k, ScopeType::DerivedTable)), "missing DerivedTable");
    assert!(kinds.iter().any(|k| matches!(k, ScopeType::Subquery)), "missing Subquery");
    assert!(kinds.iter().any(|k| matches!(k, ScopeType::SetOpBranch)), "missing SetOpBranch");
}

// ---------- unsupported ----------

#[test]
fn unsupported_create_table_as_select_returns_unsupported_query_type() {
    let sql = load_fixture("tests/fixtures/queries/unsupported/create_table_as_select.sql");
    let schema = InMemorySchema::new(vec![(
        "platinum.order_master_bi",
        vec!["order_date"],
    )]);

    let err = match resolve(&sql, schema) {
        Ok(_) => panic!("expected CTAS to be rejected as unsupported"),
        Err(e) => e,
    };

    assert!(
        matches!(err, ResolutionError::UnsupportedQueryType(_)),
        "expected UnsupportedQueryType, got {err:?}"
    );
}