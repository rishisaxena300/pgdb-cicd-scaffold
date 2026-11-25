CREATE OR REPLACE PROCEDURE dbo.add_customer
(
    p_customer_name VARCHAR(150),
    p_email VARCHAR(255),
    p_city VARCHAR(100)
)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO dbo."Customer" (customer_name, email, city)
    VALUES (p_customer_name, p_email, p_city);
END;
$$;
