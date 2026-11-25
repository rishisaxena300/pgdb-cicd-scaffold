CREATE OR REPLACE VIEW "MAAS"."CustomerSalesSummary" AS
SELECT
    c.customer_id,
    c.customer_name,
    COUNT(s.sale_id) AS total_sales,
    COALESCE(SUM(s.quantity), 0) AS total_quantity,
    COALESCE(SUM(s.quantity * s.unit_price), 0.00) AS total_sales_amount
FROM "MAAS"."Customer" c
LEFT JOIN "MAAS"."Sales" s
    ON c.customer_id = s.customer_id
GROUP BY c.customer_id, c.customer_name;
