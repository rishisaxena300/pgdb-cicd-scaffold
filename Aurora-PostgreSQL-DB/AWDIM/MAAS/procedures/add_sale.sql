CREATE OR REPLACE PROCEDURE "MAAS".add_sale
(
    p_customer_id BIGINT,
    p_product_name VARCHAR(150),
    p_quantity INTEGER,
    p_unit_price NUMERIC(12,2),
    p_sale_date DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO "MAAS"."Sales"
        (customer_id, product_name, quantity, unit_price, sale_date)
    VALUES
        (p_customer_id, p_product_name, p_quantity, p_unit_price, p_sale_date);
END;
$$;
