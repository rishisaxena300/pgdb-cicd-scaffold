CREATE TABLE "MAAS"."customer"
(
    customer_id     BIGSERIAL,
    customer_code   VARCHAR(20) NOT NULL,
    customer_name   VARCHAR(200) NOT NULL,
    email           VARCHAR(255),
    city            VARCHAR(100),
    created_date    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_customer
        PRIMARY KEY (customer_id),

    CONSTRAINT uk_customer_code
        UNIQUE (customer_code),

    CONSTRAINT uk_customer_email
        UNIQUE (email)
);

CREATE TABLE "MAAS"."sales_order"
(
    order_id         BIGSERIAL,
    customer_id      BIGINT NOT NULL,
    order_number     VARCHAR(50) NOT NULL,
    order_status     VARCHAR(30) NOT NULL,
    order_amount     NUMERIC(12,2) NOT NULL,
    order_date       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_sales_order
        PRIMARY KEY (order_id),

    CONSTRAINT uk_sales_order_number
        UNIQUE (order_number),

    CONSTRAINT fk_sales_order_customer
        FOREIGN KEY (customer_id)
        REFERENCES "MAAS"."customer"(customer_id)
        ON DELETE RESTRICT
);
