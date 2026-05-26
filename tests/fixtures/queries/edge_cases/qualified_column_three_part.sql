-- Three-part FROM identifier (`delta.platinum.order_master_bi`) with a
-- two-part column qualifier (`platinum.order_master_bi.order_date`).
-- The column qualifier should match by suffix against the table ident.
SELECT platinum.order_master_bi.order_date FROM delta.platinum.order_master_bi LIMIT 10;
