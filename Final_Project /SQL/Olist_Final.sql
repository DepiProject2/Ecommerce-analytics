/* =====================================================================
   OLIST - FINAL SQL ANALYSIS PACKAGE (Q1 + Q2 + Q3)
   Run on an existing Olist_DB (star schema already built / restored).
   Order inside this file:
     1) Q2 queries + Q3 base views and queries   (views: vw_customer_orders, vw_customers,
                                                   vw_Q2_*, vw_Q3_*)
     2) Q1 views and queries                      (views: vw_Q1_*)
   Power BI uses the views vw_Q1_*, vw_Q2_*, vw_Q3_* and the Dim tables.
   Run this script AFTER restoring Olist_DB.bak. It creates/updates analytical
   views and returns the analysis result sets. It does not insert, update, or
   delete source data. Re-running the script is safe (CREATE OR ALTER VIEW).
   Notes: payment values are not proof of unrecovered losses; late/review
   metrics are associations, not causal effects; CLV is historical, not predictive.
   ===================================================================== */

USE Olist_DB;
GO

/* =====================================================================
   PAGE 2 - ORDER FUNNEL & CONVERSION
   ===================================================================== */

/* Order Approval Rate + Order Completion Rate (Funnel) */
SELECT COUNT(*)                              AS created,
       COUNT(order_approved_at)              AS approved,
       COUNT(order_delivered_carrier_date)   AS shipped,
       COUNT(order_delivered_customer_date)  AS delivered,
       ROUND(100.0 * COUNT(order_approved_at) / COUNT(*), 2)              AS approval_rate_pct,
       ROUND(100.0 * COUNT(order_delivered_carrier_date) / COUNT(*), 2)   AS shipped_rate_pct,
       ROUND(100.0 * COUNT(order_delivered_customer_date) / COUNT(*), 2)  AS completion_rate_pct
FROM orders;

/* Cancellation Rate */
SELECT order_status,
       COUNT(*) AS orders,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM orders), 2) AS pct_of_all_orders
FROM orders
WHERE order_status IN ('canceled', 'unavailable')
GROUP BY order_status;

/* Avg. Approval Time (hours) */
SELECT ROUND(AVG(DATEDIFF(MINUTE, order_purchase_timestamp, order_approved_at) * 1.0) / 60, 2) AS avg_approval_hours
FROM orders;

/* Recorded payment value associated with canceled/unavailable orders.
   This is NOT confirmed financial loss: refunds/reversals are not modeled here. */
SELECT o.order_status,
       COUNT(DISTINCT o.order_id) AS orders,
       ROUND(SUM(p.payment_value), 2) AS recorded_payment_value
FROM orders o
JOIN order_payments p ON o.order_id = p.order_id
WHERE o.order_status IN ('canceled', 'unavailable')
GROUP BY o.order_status;

/* Payment method distribution and approval share.
   This dataset has recorded payments, not failed checkout attempts; therefore
   this metric must not be interpreted as checkout/payment conversion rate. */
SELECT p.payment_type,
       COUNT(DISTINCT o.order_id) AS orders_with_payment,
       ROUND(SUM(p.payment_value), 2) AS total_payment_value,
       ROUND(SUM(CASE WHEN o.order_approved_at IS NOT NULL THEN p.payment_value ELSE 0 END), 2) AS approved_payment_value,
       ROUND(100.0 * SUM(CASE WHEN o.order_approved_at IS NOT NULL THEN p.payment_value ELSE 0 END)
             / NULLIF(SUM(p.payment_value), 0), 2) AS approved_payment_value_share_pct
FROM orders o
JOIN order_payments p ON o.order_id = p.order_id
GROUP BY p.payment_type
ORDER BY total_payment_value DESC;
GO

/* =====================================================================
    VIEWS 
   ===================================================================== */
CREATE OR ALTER VIEW vw_customer_orders AS
SELECT c.customer_unique_id,
       c.customer_state,
       o.order_id,
       o.order_purchase_timestamp,
       ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id
                          ORDER BY o.order_purchase_timestamp, o.order_id) AS order_rank,
       p.order_value
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
LEFT JOIN (SELECT order_id, SUM(payment_value) AS order_value
           FROM order_payments
           GROUP BY order_id) p ON o.order_id = p.order_id
WHERE o.order_status = 'delivered';
GO

CREATE OR ALTER VIEW vw_customers AS
SELECT customer_unique_id,
       COUNT(*)                                          AS orders_count,
       SUM(order_value)                                  AS total_value,
       MIN(order_purchase_timestamp)                     AS first_order_date,
       MAX(CASE WHEN order_rank = 1 THEN order_id END)   AS first_order_id,
       MAX(CASE WHEN order_rank = 1 THEN customer_state END) AS first_state
FROM vw_customer_orders
GROUP BY customer_unique_id;
GO
/* =====================================================================
   PAGE 3 - CUSTOMER RETENTION & REPEAT PURCHASE
   ===================================================================== */

/* Repeat Purchase Rate */
SELECT COUNT(*) AS total_customers,
       SUM(IIF(orders_count > 1, 1, 0)) AS repeat_customers,
       ROUND(100.0 * SUM(IIF(orders_count > 1, 1, 0)) / COUNT(*), 2) AS repeat_rate_pct
FROM vw_customers;

/* Avg. Days Between Orders (first order to second order) */
SELECT COUNT(*) AS repeat_customers,
       ROUND(AVG(DATEDIFF(DAY, o1.order_purchase_timestamp, o2.order_purchase_timestamp) * 1.0), 1) AS avg_days_first_to_second
FROM vw_customer_orders o1
JOIN vw_customer_orders o2
  ON o1.customer_unique_id = o2.customer_unique_id
 AND o1.order_rank = 1
 AND o2.order_rank = 2;

/* Historical delivered-order customer value (not predictive lifetime value / forecast CLV). */
SELECT IIF(orders_count > 1, 'Repeat', 'One-time') AS customer_type,
       COUNT(*) AS customers,
       ROUND(AVG(total_value), 2) AS avg_clv,
       ROUND(SUM(total_value), 2) AS total_revenue
FROM vw_customers
GROUP BY IIF(orders_count > 1, 'Repeat', 'One-time');

/* Avg. Order Value, new (first order) vs repeat (2nd order or later) */
SELECT IIF(order_rank = 1, 'New (first order)', 'Repeat (2nd+ order)') AS order_type,
       COUNT(*) AS orders,
       ROUND(AVG(order_value), 2) AS avg_order_value
FROM vw_customer_orders
GROUP BY IIF(order_rank = 1, 'New (first order)', 'Repeat (2nd+ order)');
GO


/* =====================================================================
   PART B - ADDITIONS (Q2 + Q3 completed for Power BI)
   ===================================================================== */

/* =====================================================================
   Q2 VIEW 1: ORDER BASE
   One row per order (ALL statuses) - used for the funnel, cancellation by
   state, payment type and installments
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_Q2_OrderBase
AS
WITH Pay AS
(
    SELECT order_id,
           payment_type,
           payment_installments,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY payment_value DESC, payment_sequential) AS rn
    FROM dbo.order_payments
),
PayTotal AS
(
    SELECT order_id, SUM(payment_value) AS order_value
    FROM dbo.order_payments
    GROUP BY order_id
)
SELECT o.order_id,
       c.customer_unique_id,
       c.customer_state,
       o.order_status,
       o.order_purchase_timestamp,
       o.order_approved_at,
       o.order_delivered_carrier_date,
       o.order_delivered_customer_date,
       o.order_estimated_delivery_date,

       CASE WHEN o.order_approved_at IS NOT NULL THEN 1 ELSE 0 END             AS is_approved,
       CASE WHEN o.order_delivered_carrier_date IS NOT NULL THEN 1 ELSE 0 END  AS is_shipped,
       CASE WHEN o.order_delivered_customer_date IS NOT NULL THEN 1 ELSE 0 END AS is_delivered,
       CASE WHEN o.order_status = 'canceled' THEN 1 ELSE 0 END                 AS is_canceled,
       CASE WHEN o.order_status = 'unavailable' THEN 1 ELSE 0 END              AS is_unavailable,

       DATEDIFF(MINUTE, o.order_purchase_timestamp, o.order_approved_at) / 60.0 AS approval_hours,

       p.payment_type          AS primary_payment_type,   -- payment with the highest value in the order
       p.payment_installments  AS installments,           -- installments of that payment
       t.order_value
FROM dbo.orders o
LEFT JOIN dbo.customers c ON o.customer_id = c.customer_id
LEFT JOIN Pay p           ON o.order_id = p.order_id AND p.rn = 1
LEFT JOIN PayTotal t      ON o.order_id = t.order_id;
GO


/* =====================================================================
   Q2 VIEW 2: ORDER ITEMS (one row per item, all statuses)
   Used for cancellation by product category and by seller
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_Q2_OrderItems
AS
SELECT foi.order_id,
       foi.order_item_id,
       foi.order_status,
       dc.customer_state,
       ds.seller_id,
       ds.seller_state,
       COALESCE(NULLIF(LTRIM(RTRIM(dp.product_category_name_en)), ''),
                NULLIF(LTRIM(RTRIM(dp.product_category_name)), ''),
                'Unknown') AS product_category,
       foi.price          AS item_revenue,
       foi.freight_value
FROM dbo.FactOrderItems foi
INNER JOIN dbo.DimCustomer dc ON foi.customer_key = dc.customer_key
INNER JOIN dbo.DimProduct  dp ON foi.product_key  = dp.product_key
INNER JOIN dbo.DimSeller   ds ON foi.seller_key   = ds.seller_key;
GO


/* =====================================================================
   Q2.1 - Funnel with conversion at each stage
   ===================================================================== */
WITH F AS
(
    SELECT 1 AS stage_no, 'Created'   AS stage, COUNT(*)          AS orders FROM dbo.vw_Q2_OrderBase
    UNION ALL
    SELECT 2, 'Approved',  SUM(is_approved)  FROM dbo.vw_Q2_OrderBase
    UNION ALL
    SELECT 3, 'Shipped',   SUM(is_shipped)   FROM dbo.vw_Q2_OrderBase
    UNION ALL
    SELECT 4, 'Delivered', SUM(is_delivered) FROM dbo.vw_Q2_OrderBase
)
SELECT stage_no,
       stage,
       orders,
       ROUND(100.0 * orders / FIRST_VALUE(orders) OVER (ORDER BY stage_no), 2)         AS pct_of_created,
       ROUND(100.0 * orders / NULLIF(LAG(orders) OVER (ORDER BY stage_no), 0), 2)      AS pct_of_previous_stage
FROM F
ORDER BY stage_no;
GO


/* =====================================================================
   Q2.2 - Cancellation & unavailability rates: by state / category / seller
   ===================================================================== */

/* By customer state */
SELECT customer_state,
       COUNT(*)            AS total_orders,
       SUM(is_canceled)    AS canceled_orders,
       SUM(is_unavailable) AS unavailable_orders,
       ROUND(100.0 * SUM(is_canceled)    / NULLIF(COUNT(*), 0), 2) AS cancellation_rate_pct,
       ROUND(100.0 * SUM(is_unavailable) / NULLIF(COUNT(*), 0), 2) AS unavailability_rate_pct
FROM dbo.vw_Q2_OrderBase
WHERE customer_state IS NOT NULL
GROUP BY customer_state
ORDER BY cancellation_rate_pct DESC;
GO

/* By product category */
SELECT product_category,
       COUNT(DISTINCT order_id) AS total_orders,
       COUNT(DISTINCT CASE WHEN order_status = 'canceled'    THEN order_id END) AS canceled_orders,
       COUNT(DISTINCT CASE WHEN order_status = 'unavailable' THEN order_id END) AS unavailable_orders,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN order_status = 'canceled'    THEN order_id END)
             / NULLIF(COUNT(DISTINCT order_id), 0), 2) AS cancellation_rate_pct,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN order_status = 'unavailable' THEN order_id END)
             / NULLIF(COUNT(DISTINCT order_id), 0), 2) AS unavailability_rate_pct
FROM dbo.vw_Q2_OrderItems
GROUP BY product_category
ORDER BY cancellation_rate_pct DESC;
GO

/* By seller (small sellers give extreme %, so filter total_orders in Power BI) */
SELECT seller_id,
       seller_state,
       COUNT(DISTINCT order_id) AS total_orders,
       COUNT(DISTINCT CASE WHEN order_status = 'canceled'    THEN order_id END) AS canceled_orders,
       COUNT(DISTINCT CASE WHEN order_status = 'unavailable' THEN order_id END) AS unavailable_orders,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN order_status = 'canceled'    THEN order_id END)
             / NULLIF(COUNT(DISTINCT order_id), 0), 2) AS cancellation_rate_pct,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN order_status = 'unavailable' THEN order_id END)
             / NULLIF(COUNT(DISTINCT order_id), 0), 2) AS unavailability_rate_pct
FROM dbo.vw_Q2_OrderItems
GROUP BY seller_id, seller_state
ORDER BY cancellation_rate_pct DESC;
GO


/* =====================================================================
   Q2.3 - Payment type: approval time + order completion
   ===================================================================== */
SELECT primary_payment_type AS payment_type,
       COUNT(*) AS total_orders,
       ROUND(100.0 * SUM(is_approved)  / NULLIF(COUNT(*), 0), 2) AS approval_rate_pct,
       ROUND(AVG(approval_hours), 2)                              AS avg_approval_hours,
       ROUND(100.0 * SUM(is_delivered) / NULLIF(COUNT(*), 0), 2) AS completion_rate_pct,
       ROUND(100.0 * SUM(is_canceled)  / NULLIF(COUNT(*), 0), 2) AS cancellation_rate_pct
FROM dbo.vw_Q2_OrderBase
WHERE primary_payment_type IS NOT NULL
GROUP BY primary_payment_type
ORDER BY total_orders DESC;
GO


/* =====================================================================
   Q2.4 - Installments: conversion and average order value
   (credit card only - the other payment types have no real installments)
   ===================================================================== */
WITH CC AS
(
    SELECT *,
           CASE
               WHEN installments <= 1  THEN '1 (no installments)'
               WHEN installments <= 3  THEN '2-3'
               WHEN installments <= 6  THEN '4-6'
               WHEN installments <= 10 THEN '7-10'
               ELSE '11+'
           END AS installment_group
    FROM dbo.vw_Q2_OrderBase
    WHERE primary_payment_type = 'credit_card'
      AND installments IS NOT NULL
)
SELECT installment_group,
       COUNT(*) AS total_orders,
       ROUND(100.0 * SUM(is_approved)  / NULLIF(COUNT(*), 0), 2) AS approval_rate_pct,
       ROUND(100.0 * SUM(is_delivered) / NULLIF(COUNT(*), 0), 2) AS completion_rate_pct,
       ROUND(100.0 * SUM(is_canceled)  / NULLIF(COUNT(*), 0), 2) AS cancellation_rate_pct,
       ROUND(AVG(order_value), 2) AS avg_order_value
FROM CC
GROUP BY installment_group
ORDER BY MIN(installments);
GO


/* =====================================================================
   Q2.5 - Payment value by order outcome
   IMPORTANT: payment value for a non-delivered order is an exposure/recorded
   value, NOT confirmed revenue loss (refund/recovery data is not available).
   ===================================================================== */
SELECT
    CASE
        WHEN order_status = 'delivered' THEN 'Delivered'
        WHEN order_status IN ('canceled', 'unavailable') THEN 'Canceled / Unavailable'
        ELSE 'Pending / Not Delivered'
    END AS order_group,
    order_status,
    COUNT(*) AS total_orders,
    ROUND(SUM(COALESCE(order_value, 0)), 2) AS recorded_payment_value
FROM dbo.vw_Q2_OrderBase
GROUP BY
    CASE
        WHEN order_status = 'delivered' THEN 'Delivered'
        WHEN order_status IN ('canceled', 'unavailable') THEN 'Canceled / Unavailable'
        ELSE 'Pending / Not Delivered'
    END,
    order_status
ORDER BY order_group, order_status;
GO


/* =====================================================================
   Q3 VIEW 1: CUSTOMERS WITH FIRST-ORDER PROFILE
   One row per customer_unique_id (based on delivered orders, like vw_customers)
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_Q3_Customers
AS
WITH FirstOrderCategory AS
(
    SELECT oi.order_id,
           COALESCE(NULLIF(LTRIM(RTRIM(dp.product_category_name_en)), ''),
                    NULLIF(LTRIM(RTRIM(dp.product_category_name)), ''),
                    'Unknown') AS category,
           ROW_NUMBER() OVER (PARTITION BY oi.order_id
                              ORDER BY oi.price DESC, oi.order_item_id) AS rn
    FROM dbo.order_items oi
    INNER JOIN dbo.DimProduct dp ON oi.product_id = dp.product_id
),
FirstOrderReview AS
(
    SELECT order_id, AVG(CAST(review_score AS DECIMAL(10,2))) AS review_score
    FROM dbo.FactReviews
    GROUP BY order_id
),
FirstOrderPayment AS
(
    SELECT order_id,
           payment_type,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY payment_value DESC, payment_sequential) AS rn
    FROM dbo.order_payments
),
SecondOrder AS
(
    SELECT customer_unique_id, order_purchase_timestamp AS second_order_date
    FROM dbo.vw_customer_orders
    WHERE order_rank = 2
)
SELECT c.customer_unique_id,
       c.orders_count,
       c.total_value,
       c.first_order_date,
       c.first_order_id,
       c.first_state,
       CASE WHEN c.orders_count > 1 THEN 1 ELSE 0 END AS is_repeat_customer,

       fc.category      AS first_category,
       fr.review_score  AS first_review_score,
       CASE
           WHEN fr.review_score IS NULL THEN 'No Review'
           WHEN fr.review_score >= 4    THEN 'Positive (4-5)'
           WHEN fr.review_score >= 3    THEN 'Neutral (3)'
           ELSE 'Negative (1-2)'
       END AS first_review_group,
       fp.payment_type  AS first_payment_type,
       DATEDIFF(DAY, o.order_purchase_timestamp, o.order_delivered_customer_date) AS first_delivery_days,

       s.second_order_date,
       DATEDIFF(DAY, c.first_order_date, s.second_order_date) AS days_to_second_order
FROM dbo.vw_customers c
INNER JOIN dbo.orders o          ON o.order_id = c.first_order_id
LEFT JOIN FirstOrderCategory fc  ON fc.order_id = c.first_order_id AND fc.rn = 1
LEFT JOIN FirstOrderReview fr    ON fr.order_id = c.first_order_id
LEFT JOIN FirstOrderPayment fp   ON fp.order_id = c.first_order_id AND fp.rn = 1
LEFT JOIN SecondOrder s          ON s.customer_unique_id = c.customer_unique_id;
GO


/* =====================================================================
   Q3 VIEW 2: MONTHLY COHORT RETENTION (delivered orders only)
   cohort_month = month of first order, month_number = months since then
   retention_pct = customers who ordered again in that month / cohort size
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_Q3_Cohort
AS
WITH FirstM AS
(
    SELECT customer_unique_id,
           DATEFROMPARTS(YEAR(first_order_date), MONTH(first_order_date), 1) AS cohort_month
    FROM dbo.vw_customers
),
Act AS
(
    SELECT DISTINCT customer_unique_id,
           DATEFROMPARTS(YEAR(order_purchase_timestamp), MONTH(order_purchase_timestamp), 1) AS order_month
    FROM dbo.vw_customer_orders
),
Cohort AS
(
    SELECT f.cohort_month,
           DATEDIFF(MONTH, f.cohort_month, a.order_month) AS month_number,
           COUNT(DISTINCT a.customer_unique_id)           AS active_customers
    FROM FirstM f
    INNER JOIN Act a ON a.customer_unique_id = f.customer_unique_id
    GROUP BY f.cohort_month, DATEDIFF(MONTH, f.cohort_month, a.order_month)
)
SELECT cohort_month,
       month_number,
       active_customers,
       MAX(CASE WHEN month_number = 0 THEN active_customers END)
           OVER (PARTITION BY cohort_month) AS cohort_size,
       ROUND(100.0 * active_customers
             / NULLIF(MAX(CASE WHEN month_number = 0 THEN active_customers END)
                      OVER (PARTITION BY cohort_month), 0), 2) AS retention_pct
FROM Cohort;
GO


/* =====================================================================
   Q3.1 - Repeat purchase rate by state and by first-purchase category
   ===================================================================== */
SELECT first_state,
       COUNT(*) AS total_customers,
       SUM(is_repeat_customer) AS repeat_customers,
       ROUND(100.0 * SUM(is_repeat_customer) / NULLIF(COUNT(*), 0), 2) AS repeat_rate_pct
FROM dbo.vw_Q3_Customers
GROUP BY first_state
ORDER BY repeat_rate_pct DESC;
GO

SELECT first_category,
       COUNT(*) AS total_customers,
       SUM(is_repeat_customer) AS repeat_customers,
       ROUND(100.0 * SUM(is_repeat_customer) / NULLIF(COUNT(*), 0), 2) AS repeat_rate_pct
FROM dbo.vw_Q3_Customers
GROUP BY first_category
ORDER BY total_customers DESC;
GO


/* =====================================================================
   Q3.2 - Does a positive first-order review (4-5) increase repeat purchase?
   ===================================================================== */
SELECT first_review_group,
       COUNT(*) AS total_customers,
       SUM(is_repeat_customer) AS repeat_customers,
       ROUND(100.0 * SUM(is_repeat_customer) / NULLIF(COUNT(*), 0), 2) AS repeat_rate_pct
FROM dbo.vw_Q3_Customers
GROUP BY first_review_group
ORDER BY repeat_rate_pct DESC;
GO

/* Extra: first-order delivery time vs repeat purchase */
SELECT CASE
           WHEN first_delivery_days IS NULL THEN 'Unknown'
           WHEN first_delivery_days <= 7    THEN '0-7 days'
           WHEN first_delivery_days <= 14   THEN '8-14 days'
           WHEN first_delivery_days <= 21   THEN '15-21 days'
           ELSE '22+ days'
       END AS first_delivery_time,
       COUNT(*) AS total_customers,
       SUM(is_repeat_customer) AS repeat_customers,
       ROUND(100.0 * SUM(is_repeat_customer) / NULLIF(COUNT(*), 0), 2) AS repeat_rate_pct
FROM dbo.vw_Q3_Customers
GROUP BY CASE
           WHEN first_delivery_days IS NULL THEN 'Unknown'
           WHEN first_delivery_days <= 7    THEN '0-7 days'
           WHEN first_delivery_days <= 14   THEN '8-14 days'
           WHEN first_delivery_days <= 21   THEN '15-21 days'
           ELSE '22+ days'
       END
ORDER BY MIN(first_delivery_days);
GO

/* Extra: first-order payment method vs repeat purchase */
SELECT first_payment_type,
       COUNT(*) AS total_customers,
       SUM(is_repeat_customer) AS repeat_customers,
       ROUND(100.0 * SUM(is_repeat_customer) / NULLIF(COUNT(*), 0), 2) AS repeat_rate_pct
FROM dbo.vw_Q3_Customers
GROUP BY first_payment_type
ORDER BY total_customers DESC;
GO


/* =====================================================================
   Q3.5 - Monthly cohort retention curve
   ===================================================================== */
SELECT cohort_month, month_number, active_customers, cohort_size, retention_pct
FROM dbo.vw_Q3_Cohort
ORDER BY cohort_month, month_number;
GO


/* =====================================================================
   CHECK: all Q2 / Q3 views exist
   ===================================================================== */
SELECT name AS view_name
FROM sys.views
WHERE name LIKE 'vw_Q2_%' OR name LIKE 'vw_Q3_%' OR name IN ('vw_customer_orders', 'vw_customers')
ORDER BY name;
GO
GO


/* =====================================================================
   BUSINESS QUESTION 1 (starts here)
   ===================================================================== */

/* =========================================================
   BUSINESS QUESTION 1
   Delivery & Seller Performance Impact on Satisfaction
   and Revenue

   Permanent Views based on the existing Star Schema
   ========================================================= */


/* =========================================================
   VIEW 1: ORDER BASE
   One row per delivered order
   ========================================================= */

CREATE OR ALTER VIEW dbo.vw_Q1_OrderBase
AS
WITH ReviewByOrder AS
(
    SELECT
        order_id,
        AVG(CAST(review_score AS DECIMAL(10,2))) AS avg_review_score,
        COUNT(*) AS review_count
    FROM dbo.FactReviews
    GROUP BY order_id
),
OrderRows AS
(
    SELECT DISTINCT
        foi.order_id,
        dc.customer_unique_id,
        dc.customer_state,
        foi.order_status,
        dp.full_date AS purchase_date,
        dd.full_date AS delivered_date,
        de.full_date AS estimated_delivery_date,
        dcar.full_date AS carrier_date
    FROM dbo.FactOrderItems foi
    INNER JOIN dbo.DimCustomer dc
        ON foi.customer_key = dc.customer_key
    LEFT JOIN dbo.DimDate dp
        ON foi.purchase_date_key = dp.date_key
    LEFT JOIN dbo.DimDate dd
        ON foi.delivered_date_key = dd.date_key
    LEFT JOIN dbo.DimDate de
        ON foi.estimated_delivery_date_key = de.date_key
    LEFT JOIN dbo.DimDate dcar
        ON foi.carrier_date_key = dcar.date_key
    WHERE foi.order_status = 'delivered'
      AND foi.delivered_date_key IS NOT NULL
)
SELECT
    o.order_id,
    o.customer_unique_id,
    o.customer_state,
    o.order_status,
    o.purchase_date,
    o.delivered_date,
    o.estimated_delivery_date,
    o.carrier_date,

    /* Seller fulfillment time = days from purchase until the seller hands the order to the carrier */
    CASE
        WHEN o.carrier_date IS NULL OR o.carrier_date < o.purchase_date THEN NULL
        ELSE DATEDIFF(DAY, o.purchase_date, o.carrier_date)
    END AS fulfillment_days,

    DATEDIFF(
        DAY,
        o.estimated_delivery_date,
        o.delivered_date
    ) AS delivery_delay_days,

    CASE
        WHEN o.estimated_delivery_date IS NULL THEN NULL
        WHEN o.delivered_date > o.estimated_delivery_date THEN 1
        ELSE 0
    END AS late_flag,

    r.avg_review_score,
    ISNULL(r.review_count, 0) AS review_count

FROM OrderRows o
LEFT JOIN ReviewByOrder r
    ON o.order_id = r.order_id;
GO


/* =========================================================
   VIEW 2: ORDER ITEMS
   One row per product item
   ========================================================= */

CREATE OR ALTER VIEW dbo.vw_Q1_OrderItems
AS
SELECT
    ob.order_id,
    ob.customer_unique_id,
    ob.customer_state,

    ob.purchase_date,
    ob.delivered_date,
    ob.estimated_delivery_date,
    ob.delivery_delay_days,
    ob.late_flag,
    ob.fulfillment_days,
    ob.avg_review_score,

    foi.order_item_id,

    ds.seller_id,
    ds.seller_state,

    dp.product_id,

    COALESCE(
        NULLIF(LTRIM(RTRIM(dp.product_category_name_en)), ''),
        NULLIF(LTRIM(RTRIM(dp.product_category_name)), ''),
        'Unknown'
    ) AS product_category,

    foi.price AS item_revenue,
    foi.freight_value

FROM dbo.FactOrderItems foi

INNER JOIN dbo.vw_Q1_OrderBase ob
    ON foi.order_id = ob.order_id

INNER JOIN dbo.DimProduct dp
    ON foi.product_key = dp.product_key

INNER JOIN dbo.DimSeller ds
    ON foi.seller_key = ds.seller_key;
GO


/* =========================================================
   VIEW 3: SELLER ORDERS
   One row per order and seller
   ========================================================= */

CREATE OR ALTER VIEW dbo.vw_Q1_SellerOrders
AS
SELECT
    order_id,
    seller_id,
    seller_state,

    MAX(customer_unique_id) AS customer_unique_id,

    MAX(purchase_date) AS purchase_date,
    MAX(delivery_delay_days) AS delivery_delay_days,
    MAX(late_flag) AS late_flag,
    MAX(fulfillment_days) AS fulfillment_days,
    MAX(avg_review_score) AS avg_review_score,

    COUNT(*) AS items_count,

    SUM(item_revenue) AS seller_revenue,

    SUM(freight_value) AS seller_freight_value

FROM dbo.vw_Q1_OrderItems

GROUP BY
    order_id,
    seller_id,
    seller_state;
GO


/* =========================================================
   VIEW 4: CUSTOMER DELIVERY EXPERIENCE
   One row per customer
   ========================================================= */

CREATE OR ALTER VIEW dbo.vw_Q1_CustomerExperience
AS
WITH RankedOrders AS
(
    SELECT
        customer_unique_id,
        order_id,
        purchase_date,
        late_flag,
        ROW_NUMBER() OVER
        (
            PARTITION BY customer_unique_id
            ORDER BY purchase_date, order_id
        ) AS order_rank,
        COUNT(*) OVER
        (
            PARTITION BY customer_unique_id
        ) AS delivered_orders
    FROM dbo.vw_Q1_OrderBase
    WHERE customer_unique_id IS NOT NULL
)
SELECT
    customer_unique_id,
    MAX(delivered_orders) AS delivered_orders,
    MAX(CASE WHEN order_rank = 1 THEN late_flag END) AS first_order_late_flag,
    CASE WHEN MAX(delivered_orders) > 1 THEN 1 ELSE 0 END AS is_repeat_customer
FROM RankedOrders
GROUP BY customer_unique_id;
GO


/* =========================================================
   CHECK: VIEWS CREATED SUCCESSFULLY
   ========================================================= */

SELECT
    name AS view_name
FROM sys.views
WHERE name LIKE 'vw_Q1_%'
ORDER BY name;
GO


/* =========================================================
   QUESTION 1.1
   Late Delivery Rate by State
   ========================================================= */

SELECT
    customer_state,

    COUNT(DISTINCT CASE WHEN late_flag IS NOT NULL THEN order_id END) AS total_orders,

    COUNT(DISTINCT CASE
        WHEN late_flag = 1 THEN order_id
    END) AS late_orders,

    ROUND(
        100.0 * COUNT(DISTINCT CASE
            WHEN late_flag = 1 THEN order_id
        END)
        / NULLIF(COUNT(DISTINCT CASE WHEN late_flag IS NOT NULL THEN order_id END), 0),
        2
    ) AS late_delivery_rate_pct

FROM dbo.vw_Q1_OrderBase

GROUP BY customer_state

ORDER BY late_delivery_rate_pct DESC;
GO


/* QUESTION 1.1 - Late Delivery Rate by Product Category */

SELECT
    product_category,

    COUNT(DISTINCT CASE WHEN late_flag IS NOT NULL THEN order_id END) AS total_orders,

    COUNT(DISTINCT CASE
        WHEN late_flag = 1 THEN order_id
    END) AS late_orders,

    ROUND(
        100.0 * COUNT(DISTINCT CASE
            WHEN late_flag = 1 THEN order_id
        END)
        / NULLIF(COUNT(DISTINCT CASE WHEN late_flag IS NOT NULL THEN order_id END), 0),
        2
    ) AS late_delivery_rate_pct

FROM dbo.vw_Q1_OrderItems

GROUP BY product_category

ORDER BY late_delivery_rate_pct DESC;
GO


/* QUESTION 1.1 - Late Delivery Rate by Seller */

SELECT
    seller_id,
    seller_state,

    COUNT(DISTINCT CASE WHEN late_flag IS NOT NULL THEN order_id END) AS total_orders,

    COUNT(DISTINCT CASE
        WHEN late_flag = 1 THEN order_id
    END) AS late_orders,

    ROUND(
        100.0 * COUNT(DISTINCT CASE
            WHEN late_flag = 1 THEN order_id
        END)
        / NULLIF(COUNT(DISTINCT CASE WHEN late_flag IS NOT NULL THEN order_id END), 0),
        2
    ) AS late_delivery_rate_pct

FROM dbo.vw_Q1_SellerOrders

GROUP BY
    seller_id,
    seller_state

ORDER BY late_delivery_rate_pct DESC;
GO


/* =========================================================
   QUESTION 1.2
   Delivery Delay Impact on Customer Satisfaction
   ========================================================= */

/* Late vs On-Time */

SELECT
    CASE
        WHEN late_flag = 1 THEN 'Late'
        WHEN late_flag = 0 THEN 'On-Time / Early'
    END AS delivery_status,

    COUNT(*) AS total_orders,

    ROUND(AVG(avg_review_score), 2) AS average_review_score

FROM dbo.vw_Q1_OrderBase

WHERE late_flag IS NOT NULL
  AND avg_review_score IS NOT NULL

GROUP BY late_flag

ORDER BY late_flag DESC;
GO


/* Review Score by Delay Duration */

SELECT
    CASE
        WHEN delivery_delay_days <= 0 THEN 'On-Time / Early'
        WHEN delivery_delay_days BETWEEN 1 AND 2 THEN '1-2 Days Late'
        WHEN delivery_delay_days BETWEEN 3 AND 5 THEN '3-5 Days Late'
        WHEN delivery_delay_days BETWEEN 6 AND 10 THEN '6-10 Days Late'
        ELSE 'More Than 10 Days Late'
    END AS delay_category,

    COUNT(*) AS total_orders,

    ROUND(AVG(avg_review_score), 2) AS average_review_score

FROM dbo.vw_Q1_OrderBase

WHERE delivery_delay_days IS NOT NULL
  AND avg_review_score IS NOT NULL

GROUP BY
    CASE
        WHEN delivery_delay_days <= 0 THEN 'On-Time / Early'
        WHEN delivery_delay_days BETWEEN 1 AND 2 THEN '1-2 Days Late'
        WHEN delivery_delay_days BETWEEN 3 AND 5 THEN '3-5 Days Late'
        WHEN delivery_delay_days BETWEEN 6 AND 10 THEN '6-10 Days Late'
        ELSE 'More Than 10 Days Late'
    END

ORDER BY
    MIN(delivery_delay_days);
GO


/* =========================================================
   KPI SUMMARY
   On-Time Rate, Avg Delivery Delay, Seller Fulfillment Time
   (negative delay = delivered earlier than estimated)
   ========================================================= */

SELECT
    COUNT(*) AS delivered_orders,

    ROUND(
        100.0 * SUM(CASE WHEN late_flag = 0 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(late_flag), 0),
        2
    ) AS on_time_delivery_rate_pct,

    ROUND(AVG(CAST(delivery_delay_days AS DECIMAL(10,2))), 2)
        AS avg_delivery_delay_days,

    ROUND(AVG(CASE WHEN late_flag = 1
                   THEN CAST(delivery_delay_days AS DECIMAL(10,2)) END), 2)
        AS avg_delay_when_late_days,

    ROUND(AVG(CAST(fulfillment_days AS DECIMAL(10,2))), 2)
        AS avg_seller_fulfillment_days

FROM dbo.vw_Q1_OrderBase;
GO


/* =========================================================
   QUESTION 1.3
   Repeat Purchase Rate:
   Customers with Late vs No Late Delivery Experience
   ========================================================= */

/* Repeat purchase rate by whether the customer's FIRST delivered order was late.
   This is a descriptive association, not evidence that delay caused churn. */
SELECT
    CASE
        WHEN first_order_late_flag = 1 THEN 'First Delivered Order Was Late'
        WHEN first_order_late_flag = 0 THEN 'First Delivered Order Was On-Time'
        ELSE 'Unknown Estimated Date'
    END AS customer_group,
    COUNT(*) AS total_customers,
    SUM(is_repeat_customer) AS repeat_customers,
    ROUND(100.0 * SUM(is_repeat_customer) / NULLIF(COUNT(*), 0), 2) AS repeat_purchase_rate_pct
FROM dbo.vw_Q1_CustomerExperience
GROUP BY first_order_late_flag
ORDER BY first_order_late_flag DESC;
GO


/* =========================================================
   QUESTION 1.4
   Seller Pareto Analysis
   Permanent view (Power BI uses it) + Top 20% vs Other 80%
   ========================================================= */

CREATE OR ALTER VIEW dbo.vw_Q1_SellerPareto
AS
WITH SellerStats AS
(
    SELECT
        seller_id,
        seller_state,

        SUM(seller_revenue) AS total_seller_revenue,

        COUNT(DISTINCT order_id) AS total_orders,

        ROUND(AVG(avg_review_score), 2) AS average_review_score,

        ROUND(AVG(CAST(fulfillment_days AS DECIMAL(10,2))), 2)
            AS avg_fulfillment_days,

        ROUND(
            100.0 * SUM(CASE WHEN late_flag = 1 THEN 1 ELSE 0 END)
            / NULLIF(COUNT(*), 0),
            2
        ) AS late_order_rate_pct

    FROM dbo.vw_Q1_SellerOrders

    GROUP BY
        seller_id,
        seller_state
),
SellerRanking AS
(
    SELECT
        *,

        ROW_NUMBER() OVER (
            ORDER BY total_seller_revenue DESC, seller_id
        ) AS revenue_rank,

        COUNT(*) OVER () AS seller_count,

        SUM(total_seller_revenue) OVER () AS total_revenue,

        SUM(total_seller_revenue) OVER (
            ORDER BY total_seller_revenue DESC, seller_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_revenue

    FROM SellerStats
)
SELECT
    seller_id,
    seller_state,

    total_seller_revenue,
    total_orders,
    average_review_score,
    avg_fulfillment_days,
    late_order_rate_pct,

    revenue_rank,
    seller_count,

    CASE
        WHEN revenue_rank <= CEILING(seller_count * 0.20)
            THEN 'Top 20%'
        ELSE 'Other 80%'
    END AS seller_group,

    ROUND(
        100.0 * total_seller_revenue
        / NULLIF(total_revenue, 0),
        2
    ) AS individual_revenue_share_pct,

    ROUND(
        100.0 * cumulative_revenue
        / NULLIF(total_revenue, 0),
        2
    ) AS cumulative_revenue_share_pct

FROM SellerRanking;
GO


/* Seller Pareto - full ranking */

SELECT *
FROM dbo.vw_Q1_SellerPareto
ORDER BY revenue_rank;
GO


/* Top 20% vs Other 80%: revenue share, fulfillment time, review score, late rate
   (averages are simple averages across sellers) */

SELECT
    seller_group,

    COUNT(*) AS sellers,

    ROUND(SUM(total_seller_revenue), 2) AS group_revenue,

    ROUND(
        100.0 * SUM(total_seller_revenue)
        / NULLIF(SUM(SUM(total_seller_revenue)) OVER (), 0),
        2
    ) AS revenue_share_pct,

    ROUND(AVG(avg_fulfillment_days), 2) AS avg_fulfillment_days,

    ROUND(AVG(average_review_score), 2) AS avg_review_score,

    ROUND(AVG(late_order_rate_pct), 2) AS avg_late_order_rate_pct

FROM dbo.vw_Q1_SellerPareto

GROUP BY seller_group

ORDER BY seller_group DESC;
GO


/* =========================================================
   QUESTION 1.5
   Category Performance
   ========================================================= */

WITH CategoryOrder AS
(
    SELECT
        order_id,
        product_category,

        SUM(item_revenue) AS order_category_revenue,

        MAX(late_flag) AS late_flag,

        MAX(avg_review_score) AS avg_review_score

    FROM dbo.vw_Q1_OrderItems

    GROUP BY
        order_id,
        product_category
)
SELECT
    product_category,

    COUNT(*) AS total_orders,

    ROUND(SUM(order_category_revenue), 2) AS total_revenue,

    SUM(CASE WHEN late_flag = 1 THEN 1 ELSE 0 END) AS late_orders,

    ROUND(
        100.0 * SUM(CASE WHEN late_flag = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0),
        2
    ) AS late_delivery_rate_pct,

    ROUND(AVG(avg_review_score), 2) AS average_review_score

FROM CategoryOrder

GROUP BY product_category

ORDER BY total_revenue DESC;
GO


/* QUESTION 1.5 - Seller Performance */

SELECT
    seller_id,
    seller_state,

    COUNT(*) AS total_orders,

    ROUND(SUM(seller_revenue), 2) AS total_revenue,

    SUM(CASE WHEN late_flag = 1 THEN 1 ELSE 0 END) AS late_orders,

    ROUND(
        100.0 * SUM(CASE WHEN late_flag = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0),
        2
    ) AS late_delivery_rate_pct,

    ROUND(AVG(avg_review_score), 2) AS average_review_score

FROM dbo.vw_Q1_SellerOrders

GROUP BY
    seller_id,
    seller_state

ORDER BY total_revenue DESC;
GO


/* =========================================================
   QUESTION 1.6
   Revenue exposure proxy:
   Late delivered item revenue with low reviews (Score <= 2); not confirmed lost revenue.
   ========================================================= */

/* Overall Revenue at Risk */

SELECT
    COUNT(DISTINCT order_id) AS affected_orders,

    ROUND(SUM(item_revenue), 2) AS revenue_at_risk

FROM dbo.vw_Q1_OrderItems

WHERE late_flag = 1
  AND avg_review_score <= 2;
GO


/* Revenue at Risk by Product Category and Seller */

SELECT
    product_category,
    seller_id,

    COUNT(DISTINCT order_id) AS affected_orders,

    ROUND(SUM(item_revenue), 2) AS revenue_at_risk

FROM dbo.vw_Q1_OrderItems

WHERE late_flag = 1
  AND avg_review_score <= 2

GROUP BY
    product_category,
    seller_id

ORDER BY revenue_at_risk DESC;
GO


/* =========================================================
   ADDITIONAL KPI
   Monthly delivered item-price revenue and Month-over-Month Growth
   Excludes freight and non-delivered orders.
   ========================================================= */

WITH MonthlyRevenue AS
(
    SELECT
        YEAR(purchase_date) AS revenue_year,
        MONTH(purchase_date) AS revenue_month,

        SUM(item_revenue) AS monthly_revenue

    FROM dbo.vw_Q1_OrderItems

    WHERE purchase_date IS NOT NULL

    GROUP BY
        YEAR(purchase_date),
        MONTH(purchase_date)
),
RevenueWithPreviousMonth AS
(
    SELECT
        revenue_year,
        revenue_month,
        monthly_revenue,

        LAG(monthly_revenue) OVER (
            ORDER BY revenue_year, revenue_month
        ) AS previous_month_revenue

    FROM MonthlyRevenue
)
SELECT
    revenue_year,
    revenue_month,

    ROUND(monthly_revenue, 2) AS monthly_revenue,

    ROUND(previous_month_revenue, 2) AS previous_month_revenue,

    ROUND(
        100.0 * (monthly_revenue - previous_month_revenue)
        / NULLIF(previous_month_revenue, 0),
        2
    ) AS mom_growth_pct

FROM RevenueWithPreviousMonth

ORDER BY
    revenue_year,
    revenue_month;
GO