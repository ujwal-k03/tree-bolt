-- CREATE TABLE … AS SELECT is currently treated as an unsupported statement
-- type by the resolver. Inner SELECT uses a column qualified by the unaliased
-- table's last ident part (`order_master_bi.order_date`).
CREATE TABLE asd AS
SELECT order_master_bi.order_date FROM platinum.order_master_bi;
