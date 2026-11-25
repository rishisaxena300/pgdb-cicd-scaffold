CREATE OR REPLACE FUNCTION "MAAS".fn_sales_validate()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.product_name := TRIM(NEW.product_name);
    IF NEW.sale_date > CURRENT_DATE THEN
        RAISE EXCEPTION
            'Sale date % cannot be later than the current date %',
            NEW.sale_date,
            CURRENT_DATE;
    END IF;
    RETURN NEW;
END;
$$;
