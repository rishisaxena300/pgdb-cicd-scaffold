DROP TRIGGER IF EXISTS trg_customer_normalize ON "MAAS"."Customer";

CREATE TRIGGER trg_customer_normalize
BEFORE INSERT OR UPDATE ON "MAAS"."Customer"
FOR EACH ROW
EXECUTE FUNCTION "MAAS".fn_customer_normalize();
