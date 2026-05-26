mod common;

use common::{resolve, InMemorySchema};

use treebolt::resolve::errors::ResolutionError;
use treebolt::resolve::scope::sources::{ResolvedSource, Source};
use treebolt::resolve::scope::{ColumnRef, ScopeType};

#[test]
fn simple_select_resolves_root_scope_with_table_source() {
    let schema = InMemorySchema::new(vec![("users", vec!["id", "name", "email"])]);

    let scopes = resolve("SELECT id, name FROM users", schema).expect("resolve");

    // Index 0 is the synthetic Boundary scope; index 1 is the Root scope for the query.
    assert_eq!(scopes.len(), 2);
    assert!(matches!(scopes[0].scope_type, ScopeType::Boundary));
    assert!(matches!(scopes[1].scope_type, ScopeType::Root));

    let root = &scopes[1];

    assert_eq!(root.sources.len(), 1);
    let source = root.sources.get("users").expect("users source registered");
    match source {
        ResolvedSource::Table(t) => {
            assert_eq!(t.ident, vec!["users".to_string()]);
            assert_eq!(t.list_cols(), &["id", "name", "email"]);
        }
        _ => panic!("expected TableSource"),
    }

    let names: Vec<_> = root.selected_columns.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["id", "name"]);

    let id_deps = &root.selected_columns[0].dependencies;
    assert!(id_deps.contains(&ColumnRef { name: "id".into(), source_name: "users".into() }));
}

#[test]
fn unknown_table_returns_table_not_found() {
    let schema = InMemorySchema::new(vec![("users", vec!["id"])]);

    let err = match resolve("SELECT id FROM orders", schema) {
        Ok(_) => panic!("expected error"),
        Err(e) => e,
    };

    assert!(
        matches!(err, ResolutionError::TableNotFound(_)),
        "expected TableNotFound, got {err:?}"
    );
}

#[test]
fn unknown_column_returns_column_not_found() {
    let schema = InMemorySchema::new(vec![("users", vec!["id"])]);

    let err = match resolve("SELECT missing FROM users", schema) {
        Ok(_) => panic!("expected error"),
        Err(e) => e,
    };

    assert!(
        matches!(err, ResolutionError::ColumnNotFound(_)),
        "expected ColumnNotFound, got {err:?}"
    );
}

#[test]
fn aliased_projection_uses_alias_as_selected_name() {
    let schema = InMemorySchema::new(vec![("users", vec!["id", "name"])]);

    let scopes = resolve("SELECT name AS full_name FROM users", schema).expect("resolve");

    let root = &scopes[1];
    assert_eq!(root.selected_columns.len(), 1);
    assert_eq!(root.selected_columns[0].name, "full_name");
    assert!(root.selected_columns[0].dependencies.contains(&ColumnRef {
        name: "name".into(),
        source_name: "users".into(),
    }));
}