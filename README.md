# Olist E-Commerce Analytics

**DEPI Professional Data Analytics Capstone**

End-to-end analysis of ~100K orders from the Brazilian marketplace **Olist** (Sep 2016 - Oct 2018): data cleaning and EDA in **Python**, a **star schema** and KPI queries in **SQL Server**, and an interactive **Power BI** dashboard.

## Team
| Member | Role |
|---|---|
| Karim | SQL Server: database, star schema, KPI views |
| Asmaa | Python: data cleaning, EDA, cohort retention |
| Ahmed Anany | Power BI dashboard and DAX measures |
| Mohamed Ali | Analytical questions, RFM analysis, final report |

## Business questions
1. How do sales and revenue evolve, and which categories and states drive them?
2. How reliable is delivery, and how does it affect customer satisfaction?
3. How many customers come back (cohort retention, RFM)?

## Tools
Python (pandas, matplotlib/seaborn, Jupyter) | SQL Server + SSMS | Power BI Desktop

## Dataset
[Olist Brazilian E-Commerce Public Dataset (Kaggle)](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) - 9 CSV files: customers, orders, order_items, order_payments, order_reviews, products, sellers, geolocation, product_category_name_translation.

## Repository structure
```
notebooks/      Python: cleaning, EDA, cohort retention
sql_scripts/    star_schema_olist.sql + KPI views
dashboard/      Power BI file (.pbix) and screenshots
docs/           ERD, data dictionary, documentation, presentation
data/           (raw CSVs are not committed - download from Kaggle)
```

## How to run
1. Download the 9 CSV files from Kaggle into `data/raw/`.
2. Run the notebooks in `notebooks/` in order (cleaning -> EDA -> cohort). Cleaned files are saved to `data/clean/`.
3. In SQL Server create a database `OlistDB`, run `sql_scripts/star_schema_olist.sql`, then load the cleaned data into the dimension and fact tables.
4. Open the `.pbix` file in Power BI Desktop and point the data source to your `OlistDB`.

## Data model (star schema)
3 fact tables - `FactOrderItems`, `FactPayments`, `FactReviews` - and 5 dimensions - `DimDate`, `DimCustomer`, `DimProduct`, `DimSeller`, `DimGeolocation`. See `docs/erd_olist.png`.

Key decisions: canceled orders are excluded from KPIs; revenue = sum of item `price` (freight excluded); the real customer is `customer_unique_id`; payments and reviews are separate facts to avoid duplicating revenue.

## Key results
| KPI | Value |
|---|---|
| Revenue (excl. canceled) | $13.50M |
| Valid orders | 98,205 |
| Average order value | $137.4 |
| Average delivery time | 12.1 days |
| Late deliveries | 8.1% |
| Average review score | 4.09 / 5 (late orders: 2.57, on time: 4.29) |
| Customers with 2+ orders | 3.1% |

Top categories: health_beauty, watches_gifts, bed_bath_table. Sao Paulo = 38% of revenue.

## Documentation and presentation
See the `docs/` folder: project documentation, ERD, data dictionary, presentation PDF and demo video link.
