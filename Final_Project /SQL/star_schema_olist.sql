/* =====================================================================
   Olist E-Commerce Analytics - Star Schema (SQL Server)
   Database : OlistDB
   Design   : 3 fact tables (constellation) + 5 dimensions
   Source   : cleaned data (Python) based on the 9 Olist CSV files
   Types    : follow Data_Dictionary_updated.xlsx
   ===================================================================== */

USE OlistDB;
GO

/* ---------- Drop in dependency order (safe re-run) ---------- */
DROP TABLE IF EXISTS dbo.FactReviews;
DROP TABLE IF EXISTS dbo.FactPayments;
DROP TABLE IF EXISTS dbo.FactOrderItems;
DROP TABLE IF EXISTS dbo.DimGeolocation;
DROP TABLE IF EXISTS dbo.DimSeller;
DROP TABLE IF EXISTS dbo.DimProduct;
DROP TABLE IF EXISTS dbo.DimCustomer;
DROP TABLE IF EXISTS dbo.DimDate;
GO

/* =====================================================================
   DIMENSIONS
   ===================================================================== */

/* DimDate - one row per calendar day. date_key = YYYYMMDD.
   Used as a role-playing dimension (purchase, approved, carrier,
   delivered, estimated, shipping limit, review dates). */
CREATE TABLE dbo.DimDate (
    date_key        INT          NOT NULL PRIMARY KEY,   -- e.g. 20180315
    full_date       DATE         NOT NULL UNIQUE,
    [year]          SMALLINT     NOT NULL,
    [quarter]       TINYINT      NOT NULL,
    [month]         TINYINT      NOT NULL,
    month_name      VARCHAR(10)  NOT NULL,
    year_month      CHAR(7)      NOT NULL,               -- e.g. 2018-03
    [day]           TINYINT      NOT NULL,
    day_of_week     TINYINT      NOT NULL,               -- 1 = Monday
    day_name        VARCHAR(10)  NOT NULL,
    is_weekend      BIT          NOT NULL
);

/* DimCustomer - one row per customer_id (per order).
   customer_unique_id identifies the real person (use it for retention,
   cohort and RFM analysis). */
CREATE TABLE dbo.DimCustomer (
    customer_key             INT IDENTITY(1,1) PRIMARY KEY,
    customer_id              VARCHAR(32)   NOT NULL UNIQUE,
    customer_unique_id       VARCHAR(32)   NOT NULL,
    customer_zip_code_prefix VARCHAR(5)    NOT NULL,
    customer_city            NVARCHAR(100) NOT NULL,
    customer_state           VARCHAR(2)    NOT NULL
);

/* DimProduct - includes the English category from the translation table
   ('Unknown' where the category is NULL or has no translation). */
CREATE TABLE dbo.DimProduct (
    product_key                 INT IDENTITY(1,1) PRIMARY KEY,
    product_id                  VARCHAR(32)   NOT NULL UNIQUE,
    product_category_name       VARCHAR(100)  NULL,      -- Portuguese
    product_category_name_en    VARCHAR(100)  NOT NULL,  -- English / 'Unknown'
    product_name_length         INT           NULL,      -- source typo: "lenght"
    product_description_length  INT           NULL,
    product_photos_qty          INT           NULL,
    product_weight_g            INT           NULL,
    product_length_cm           INT           NULL,
    product_height_cm           INT           NULL,
    product_width_cm            INT           NULL
);

CREATE TABLE dbo.DimSeller (
    seller_key             INT IDENTITY(1,1) PRIMARY KEY,
    seller_id              VARCHAR(32)   NOT NULL UNIQUE,
    seller_zip_code_prefix VARCHAR(5)    NOT NULL,
    seller_city            NVARCHAR(100) NOT NULL,
    seller_state           VARCHAR(2)    NOT NULL
);

/* DimGeolocation - geolocation file aggregated to ONE row per zip prefix
   (average lat/lng) so it can be used for maps in Power BI.
   Linked logically to customers/sellers by zip prefix (no FK, because
   not every prefix is guaranteed to exist). */
CREATE TABLE dbo.DimGeolocation (
    zip_code_prefix VARCHAR(5)     NOT NULL PRIMARY KEY,
    avg_lat         DECIMAL(12,9)  NOT NULL,
    avg_lng         DECIMAL(12,9)  NOT NULL,
    city            NVARCHAR(100)  NOT NULL,
    state           VARCHAR(2)     NOT NULL
);
GO

/* =====================================================================
   FACT TABLES
   ===================================================================== */

/* FactOrderItems - GRAIN: one row per order item (order_id + order_item_id).
   Main fact table for sales, delivery and category KPIs.
   Order-level attributes (status, dates) are stored here as degenerate
   attributes / date keys. */
CREATE TABLE dbo.FactOrderItems (
    order_id                     VARCHAR(32)   NOT NULL,
    order_item_id                INT           NOT NULL,
    customer_key                 INT           NOT NULL REFERENCES dbo.DimCustomer(customer_key),
    product_key                  INT           NOT NULL REFERENCES dbo.DimProduct(product_key),
    seller_key                   INT           NOT NULL REFERENCES dbo.DimSeller(seller_key),
    purchase_date_key            INT           NOT NULL REFERENCES dbo.DimDate(date_key),
    approved_date_key            INT           NULL     REFERENCES dbo.DimDate(date_key),
    carrier_date_key             INT           NULL     REFERENCES dbo.DimDate(date_key),
    delivered_date_key           INT           NULL     REFERENCES dbo.DimDate(date_key),
    estimated_delivery_date_key  INT           NOT NULL REFERENCES dbo.DimDate(date_key),
    shipping_limit_date_key      INT           NOT NULL REFERENCES dbo.DimDate(date_key),
    order_status                 VARCHAR(20)   NOT NULL,
    price                        DECIMAL(10,2) NOT NULL,   -- measure (Revenue)
    freight_value                DECIMAL(10,2) NOT NULL,   -- measure
    delivery_days                INT           NULL,       -- delivered - purchase
    delivery_delay_days          INT           NULL,       -- delivered - estimated (>0 = late)
    is_late                      BIT           NULL,
    CONSTRAINT PK_FactOrderItems PRIMARY KEY (order_id, order_item_id)
);

/* FactPayments - GRAIN: one row per payment (order_id + payment_sequential).
   Kept separate from items because one order can have several payments;
   joining both at order level would duplicate revenue. */
CREATE TABLE dbo.FactPayments (
    order_id              VARCHAR(32)   NOT NULL,
    payment_sequential    INT           NOT NULL,
    customer_key          INT           NOT NULL REFERENCES dbo.DimCustomer(customer_key),
    purchase_date_key     INT           NOT NULL REFERENCES dbo.DimDate(date_key),
    payment_type          VARCHAR(20)   NOT NULL,
    payment_installments  INT           NOT NULL,
    payment_value         DECIMAL(10,2) NOT NULL,
    CONSTRAINT PK_FactPayments PRIMARY KEY (order_id, payment_sequential)
);

/* FactReviews - GRAIN: one row per review (review_id + order_id).
   (review_id is not unique on its own in the source data.) */
CREATE TABLE dbo.FactReviews (
    review_id                VARCHAR(32)   NOT NULL,
    order_id                 VARCHAR(32)   NOT NULL,
    customer_key             INT           NOT NULL REFERENCES dbo.DimCustomer(customer_key),
    review_creation_date_key INT           NOT NULL REFERENCES dbo.DimDate(date_key),
    review_answer_date_key   INT           NULL     REFERENCES dbo.DimDate(date_key),
    review_score             INT           NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title     NVARCHAR(100) NULL,
    review_comment_message   NVARCHAR(500) NULL,
    CONSTRAINT PK_FactReviews PRIMARY KEY (review_id, order_id)
);
GO

/* Helpful indexes for the KPI queries */
CREATE INDEX IX_FactOrderItems_purchase_date ON dbo.FactOrderItems(purchase_date_key);
CREATE INDEX IX_FactOrderItems_product       ON dbo.FactOrderItems(product_key);
CREATE INDEX IX_FactOrderItems_customer      ON dbo.FactOrderItems(customer_key);
CREATE INDEX IX_FactPayments_order           ON dbo.FactPayments(order_id);
CREATE INDEX IX_FactReviews_order            ON dbo.FactReviews(order_id);
GO

/* =====================================================================
   EXAMPLE KPI QUERIES (valid orders = status <> 'canceled')
   ===================================================================== */

-- Total revenue, orders, AOV
SELECT SUM(price)                                   AS total_revenue,
       COUNT(DISTINCT order_id)                     AS total_orders,
       SUM(price) / COUNT(DISTINCT order_id)        AS avg_order_value
FROM   dbo.FactOrderItems
WHERE  order_status <> 'canceled';

-- Orders and revenue per month
SELECT d.year_month,
       COUNT(DISTINCT f.order_id) AS orders,
       SUM(f.price)               AS revenue
FROM   dbo.FactOrderItems f
JOIN   dbo.DimDate d ON d.date_key = f.purchase_date_key
WHERE  f.order_status <> 'canceled'
GROUP  BY d.year_month
ORDER  BY d.year_month;

-- Revenue by product category
SELECT p.product_category_name_en AS category, SUM(f.price) AS revenue
FROM   dbo.FactOrderItems f
JOIN   dbo.DimProduct p ON p.product_key = f.product_key
WHERE  f.order_status <> 'canceled'
GROUP  BY p.product_category_name_en
ORDER  BY revenue DESC;

-- On-time delivery rate by customer state
SELECT c.customer_state,
       AVG(CASE WHEN f.is_late = 0 THEN 1.0 ELSE 0 END) AS on_time_rate
FROM   dbo.FactOrderItems f
JOIN   dbo.DimCustomer c ON c.customer_key = f.customer_key
WHERE  f.delivered_date_key IS NOT NULL
GROUP  BY c.customer_state;
