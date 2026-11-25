DROP TRIGGER IF EXISTS trg_sales_validate ON "MAAS"."Sales";

CREATE TRIGGER trg_sales_validate
BEFORE INSERT OR UPDATE ON "MAAS"."Sales"
FOR EACH ROW
EXECUTE FUNCTION "MAAS".fn_sales_validate();
