# Wildcard expansion and additional options

Reference for `WildcardAdditionalOptions` (sqlparser): what each option does, with examples. Apply in this order when resolving: **expand \*** → **ILIKE** → **EXCLUDE/EXCEPT** → **REPLACE** → **RENAME**.

---

## 1. ILIKE (Snowflake)

**AST:** `IlikeSelectItem { pattern: String }`  
**Syntax:** `* ILIKE '<pattern>'`

**Semantics:** After expanding `*` to the column list, keep only columns whose **name** matches the pattern. Case-insensitive. SQL wildcards: `_` = one character, `%` = zero or more characters.

| Example | Effect |
|--------|--------|
| `SELECT * ILIKE '%id%' FROM t` | Only columns whose name contains `id` (e.g. `employee_id`, `department_id`) |
| `SELECT * ILIKE 'col_%' FROM t` | Only columns whose name starts with `col_` and one more character |

**Resolution:** Expand `*` to all columns → filter to columns where `column_name` matches `pattern` (e.g. `LIKE pattern` in case-insensitive mode).

---

## 2. EXCLUDE (Snowflake)

**AST:** `ExcludeSelectItem::Single(Ident)` or `ExcludeSelectItem::Multiple(Vec<Ident>)`  
**Syntax:** `* EXCLUDE col` or `* EXCLUDE (col1, col2, ...)`

**Semantics:** After expanding `*`, remove the listed columns from the result. Single column: no parentheses; multiple: parentheses required.

| Example | Effect |
|--------|--------|
| `SELECT * EXCLUDE department_id FROM employee_table` | All columns except `department_id` |
| `SELECT * EXCLUDE (department_id, employee_id) FROM employee_table` | All columns except those two |

**Resolution:** Expand `*` → drop any column whose name is in the EXCLUDE list.

---

## 3. EXCEPT (BigQuery, ClickHouse)

**AST:** `ExceptSelectItem { first_element: Ident, additional_elements: Vec<Ident> }`  
**Syntax:** `* EXCEPT (col1 [, col2, ...])` - parentheses always (at least one column).

**Semantics:** Same as EXCLUDE: omit the listed columns from the expanded `*`. BigQuery/ClickHouse use the name EXCEPT and require parentheses.

| Example | Effect |
|--------|--------|
| `SELECT * EXCEPT (order_id) FROM orders` | All columns except `order_id` |
| `SELECT * EXCEPT (a, b) FROM t` | All columns except `a` and `b` |

**Resolution:** Same as EXCLUDE: expand `*` → remove columns whose names are in the EXCEPT list.

---

## 4. REPLACE (BigQuery, Snowflake, ClickHouse)

**AST:** `ReplaceSelectItem { items: Vec<ReplaceSelectElement> }` where `ReplaceSelectElement { expr: Expr, column_name: Ident, as_keyword: bool }`  
**Syntax:** `* REPLACE (expr AS col_name [, ...])`

**Semantics:** Expand `*` as usual. For each `(expr AS col_name)`, the column **named** `col_name` is **replaced** in the result: same position and output name, but the value is `expr` (which can reference other columns). Does not add or remove columns; only replaces value (and possibly type).

| Example | Effect |
|--------|--------|
| `SELECT * REPLACE ('DEPT-' \|\| department_id AS department_id) FROM t` | All columns; `department_id` column now shows values like `DEPT-1`, `DEPT-2` |
| `SELECT * REPLACE (quantity/2 AS quantity) FROM orders` | All columns; `quantity` column shows half of original |
| `SELECT * REPLACE ("widget" AS item_name) FROM orders` | All columns; `item_name` column is literal `"widget"` |

**Resolution:** Expand `*` → for each REPLACE item, find the column with name `column_name` and treat that select-list entry as `expr AS column_name` (same name, new expression).

---

## 5. RENAME (Snowflake)

**AST:** `RenameSelectItem::Single(IdentWithAlias)` or `RenameSelectItem::Multiple(Vec<IdentWithAlias>)`  
**Syntax:** `* RENAME col AS alias` or `* RENAME (col1 AS a1, col2 AS a2, ...)`

**Semantics:** After expanding `*`, rename the listed columns in the result. Column values unchanged; only output name changes.

| Example | Effect |
|--------|--------|
| `SELECT * RENAME department_id AS department FROM t` | All columns; `department_id` appears as `department` |
| `SELECT * RENAME (department_id AS dept, employee_id AS id) FROM t` | All columns; two columns renamed |

**Resolution:** Expand `*` (and apply EXCLUDE/EXCEPT/REPLACE if present) → for each RENAME entry, change the output name of column `ident` to `alias`.

---

## Application order for resolver

1. **Expand wildcard** to the list of column identifiers (from scope: table/alias or expression type).
2. **ILIKE:** Filter that list to columns whose name matches the pattern.
3. **EXCLUDE / EXCEPT:** Remove from the list any column whose name is in the exclude/except list.
4. **REPLACE:** For each REPLACE item, replace the **expression** of the column with that name by the given `expr` (output name unchanged).
5. **RENAME:** For each RENAME item, change the **output name** of the column to the given alias.

Result: every wildcard is replaced by a list of select items: each is either a bare column identifier (possibly with a new alias from RENAME) or an expression (from REPLACE) with an optional alias.

---

## Multiple select items with different options

Each comma-separated term in the SELECT list is a **separate** `SelectItem` with its **own** `WildcardAdditionalOptions`.

**Example:** `SELECT t.* EXCLUDE (a, b),  t.* ILIKE '%id%' FROM t`

- **First item:** `QualifiedWildcard(ObjectName(t), options1)` with `opt_exclude = (a, b)`.
- **Second item:** `QualifiedWildcard(ObjectName(t), options2)` with `opt_ilike = '%id%'`.

**Resolution:** Resolve **each** select item independently (expand wildcard, apply that item’s options). The final select list is the **concatenation** of the expanded lists in order. Duplicate column names in the result are allowed (e.g. `id` can appear from both items if it matches ILIKE and wasn’t excluded in the first).

---

## Unqualified * with duplicate column names (e.g. EXCLUDE)

**Example:** `SELECT * EXCLUDE (a) FROM t1 JOIN t2` where both `t1` and `t2` have a column named `a`.

- Unqualified `*` expands to **all columns from all tables** in the join (e.g. t1’s columns then t2’s columns), so there are **two** columns named `a`.
- **EXCLUDE (a)** means: remove **every** column whose **name** is `a`. So **both** `t1.a` and `t2.a` are excluded. Matching is by name only; there is no ambiguity.

**Resolver:** When applying EXCLUDE (or EXCEPT) to an unqualified wildcard, remove every column whose name is in the exclude list, regardless of which table it came from. Same idea applies to ILIKE (keep all columns whose name matches, from any table) and RENAME (rename every column with that name, if you support it on unqualified *).

---

## Dialect summary

| Option | Snowflake | BigQuery | ClickHouse |
|--------|-----------|----------|------------|
| ILIKE  | ✓         | -        | -          |
| EXCLUDE| ✓         | -        | -          |
| EXCEPT | -         | ✓        | ✓          |
| REPLACE| ✓         | ✓        | ✓          |
| RENAME | ✓         | -        | -          |

(Your resolver can support any subset; sqlparser parses all and you apply only what your dialect allows.)

---

## QualifiedWildcard with Expr (expression.\*)

`SelectItemQualifiedWildcardKind` can be:

- **ObjectName** - e.g. `alias.*`, `schema.table.*` (expand columns of that table/alias).
- **Expr** - e.g. `struct_col.*`, `(STRUCT('a' AS x, 'b' AS y)).*` (expand fields of a struct/row-typed expression).

**Which languages:** In sqlparser, `supports_select_expr_star()` is **true** only for **BigQuery** and **Snowflake** (see `dialect/bigquery.rs` and `dialect/snowflake.rs`). Generic and other dialects return false, so they never parse `expr.*` as a qualified wildcard.

**Semantics (BigQuery):** The expression must be either a **table alias** or an expression that evaluates to a value with **fields** (e.g. a STRUCT). `expression.*` produces one output column per top-level field; column names are the struct field names.

**Examples (BigQuery):**

- `SELECT g.* FROM groceries AS g` - table alias: same as table’s columns (ObjectName could be used here too; parser may still use Expr for alias).
- `SELECT l.location.* FROM locations l` - `location` is a STRUCT column; result columns are the struct’s fields (e.g. `city`, `state`).
- `SELECT l.LOCATION[OFFSET(0)].* FROM ...` - array of structs; element is a struct, so `.*` expands to that struct’s fields.

**Resolver:** For `QualifiedWildcard(Expr(expr), options)` you need the **type** of `expr`. If it’s a struct/row type, expand to that type’s field names (and optionally apply the same ILIKE/EXCLUDE/EXCEPT/REPLACE/RENAME options). If it’s a table alias, expand to the table’s columns. You cannot expand from a bare identifier or literal unless the type is known to be a struct.
