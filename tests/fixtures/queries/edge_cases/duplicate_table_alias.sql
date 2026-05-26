-- Same table joined to itself with the same alias `a` on both sides.
SELECT 1 FROM platinum.order_master_bi AS a, platinum.order_master_bi AS a LIMIT 10;
