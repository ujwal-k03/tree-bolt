//! Shared test helpers for integration tests.
//!
//! `cargo` builds each file in `tests/` as its own crate, so anything we want
//! to share goes here and is pulled in with `mod common;`.

use std::collections::HashMap;

use sqlparser::dialect::GenericDialect;
use sqlparser::parser::Parser;

use treebolt::resolve::errors::ResolutionError;
use treebolt::resolve::scope::ResolvedScope;
use treebolt::resolve::{ResolutionOptions, Resolver};
use treebolt::schema::{SchemaProvider, TableSchema};

pub struct InMemorySchema {
    tables: HashMap<String, Vec<String>>,
}

impl InMemorySchema {
    pub fn new<I, S>(entries: I) -> Self
    where
        I: IntoIterator<Item = (&'static str, Vec<S>)>,
        S: Into<String>,
    {
        let tables = entries
            .into_iter()
            .map(|(k, cols)| (k.to_string(), cols.into_iter().map(Into::into).collect()))
            .collect();
        Self { tables }
    }
}

impl SchemaProvider for InMemorySchema {
    fn get_schema(&self, ident: &Vec<String>) -> Option<TableSchema> {
        self.tables
            .get(&ident.join("."))
            .map(|cols| TableSchema { columns: cols.clone() })
    }
}

pub fn resolve(
    sql: &str,
    schema: InMemorySchema,
) -> Result<Vec<ResolvedScope>, ResolutionError> {
    let mut parsed = Parser::parse_sql(&GenericDialect {}, sql).expect("parse sql");
    let resolver = Resolver::new(
        schema,
        ResolutionOptions { expand_select_wildcards: false, qualify: false },
    );
    resolver.resolve(&mut parsed[0])
}

/// Read a fixture SQL file from `tests/fixtures/queries/...` relative to the crate root.
pub fn load_fixture(rel_path: &str) -> String {
    let root = env!("CARGO_MANIFEST_DIR");
    let full = format!("{root}/{rel_path}");
    std::fs::read_to_string(&full).unwrap_or_else(|e| panic!("read {full}: {e}"))
}