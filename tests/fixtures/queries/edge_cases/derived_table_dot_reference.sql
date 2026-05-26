-- Reference a derived table's column via its alias: `T.order_date`.
SELECT T.order_date FROM (SELECT * FROM platinum.order_master_bi WHERE true) AS T;
