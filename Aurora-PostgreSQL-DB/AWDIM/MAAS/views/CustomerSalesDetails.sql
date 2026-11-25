CREATE OR REPLACE VIEW "MAAS"."CustomerSalesDetails" AS
SELECT
    c.customer_id,
    c.customer_name,
    c.email,
    c.city,
    s.sale_id,
    s.product_name,
    s.quantity,
    s.unit_price,
    s.quantity * s.unit_price AS total_amount,
    s.sale_date
FROM "MAAS"."Customer" c
LEFT JOIN "MAAS"."Sales" s
    ON c.customer_id = s.customer_id;
