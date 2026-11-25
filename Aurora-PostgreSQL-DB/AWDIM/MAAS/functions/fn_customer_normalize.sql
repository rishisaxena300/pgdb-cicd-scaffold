CREATE OR REPLACE FUNCTION "MAAS".fn_customer_normalize()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.customer_name := TRIM(NEW.customer_name);
    NEW.email := LOWER(TRIM(NEW.email));
    NEW.city := TRIM(NEW.city);
    RETURN NEW;
END;
$$;
