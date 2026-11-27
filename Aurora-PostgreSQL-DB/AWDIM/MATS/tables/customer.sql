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


INSERT INTO "MAAS"."customer"
(
    customer_code,
    customer_name,
    email,
    city
)
VALUES
('CUST001','John Smith','john@test.com','Sydney'),
('CUST002','Mary Jones','mary@test.com','Melbourne'),
('CUST003','David Lee','david@test.com','Brisbane');

INSERT INTO "MAAS"."sales_order"
(
    customer_id,
    order_number,
    order_status,
    order_amount
)
VALUES
(1,'ORD001','NEW',1000),
(1,'ORD002','SHIPPED',2000),
(2,'ORD003','DELIVERED',1500);
