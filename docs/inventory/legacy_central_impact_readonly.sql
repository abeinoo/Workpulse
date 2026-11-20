-- READ-ONLY impact report: legacy product-wide low-stock / reorder values -> each business's central warehouse.
-- Mirrors Inventory::LegacyCentralSettingsBackfill#dry_run (categories and their order) exactly; the
-- authoritative preview is `bin/rails inventory:legacy_central_settings_transfer` (also read-only).
-- Transition (owner decision 2026-11-20): a product's legacy total alert (LowStockQuery: active, tracked,
-- alerts on, NO row in a central warehouse — branch rows do not end it; fires at total stock <= reorder_level,
-- so level 0 = out of stock)
-- stops when its central row is created; the central alert (threshold > 0) replaces it. legacy_alert_only =
-- relies on the legacy alert but has no legacy values to transfer (exception, kept until reviewed).
--
-- Run by an operator, never by the application:
--   PGOPTIONS='-c default_transaction_read_only=on' psql -X -v ON_ERROR_STOP=1 -d <production database> -f legacy_central_impact_readonly.sql
-- The session is read-only: any write would be rejected by PostgreSQL. Nothing here writes.
-- Warehouse ids are reported, never assumed: they differ between environments.
--
-- STEP 0 FIRST. Sections 3-7 need warehouses.kind / warehouses.status / branches.branch_type and
-- product_warehouse_settings.status. If step 0 shows any of them missing, STOP after step 0 and
-- send the output back: the matching migrations are not applied in this environment yet.

\echo '== 0. Pre-flight: schema version and required columns (expect 4 rows, all present = t)'
SELECT MAX(version) AS schema_version FROM schema_migrations;
SELECT c.table_name, c.column_name,
       EXISTS (SELECT 1 FROM information_schema.columns i
               WHERE i.table_schema = 'public' AND i.table_name = c.table_name AND i.column_name = c.column_name) AS present
FROM (VALUES ('warehouses', 'kind'), ('warehouses', 'status'), ('branches', 'branch_type'),
             ('product_warehouse_settings', 'status')) AS c(table_name, column_name);

\echo '== 1. Businesses and their warehouses by kind/status (independent per business)'
SELECT b.id AS business_id,
       COUNT(w.id) FILTER (WHERE w.kind = 'central' AND w.status = 'active')   AS active_central,
       COUNT(w.id) FILTER (WHERE w.kind = 'central' AND w.status <> 'active')  AS inactive_central,
       COUNT(w.id) FILTER (WHERE w.kind = 'branch')                             AS branch_warehouses,
       COUNT(w.id) FILTER (WHERE w.kind IS NULL)                                AS unclassified,
       CASE COUNT(w.id) FILTER (WHERE w.kind = 'central' AND w.status = 'active')
         WHEN 1 THEN 'resolved' WHEN 0 THEN 'UNRESOLVED: no active central'
         ELSE 'UNRESOLVED: several active central' END                         AS central_target
FROM businesses b LEFT JOIN warehouses w ON w.business_id = b.id
GROUP BY b.id ORDER BY b.id;

\echo '== 2. Every central warehouse (ids as they are in THIS environment)'
SELECT w.business_id, w.id AS warehouse_id, w.name, w.status
FROM warehouses w WHERE w.kind = 'central' ORDER BY w.business_id, w.id;

\echo '== 3. Existing central availability rows by status (Active / Inactive)'
SELECT w.business_id, w.id AS warehouse_id, s.status, COUNT(*) AS rows
FROM product_warehouse_settings s JOIN warehouses w ON w.id = s.warehouse_id
WHERE w.kind = 'central'
GROUP BY w.business_id, w.id, s.status ORDER BY 1, 2, 3;

\echo '== 4. Classification per business (same rules and order as the backfill dry run)'
WITH target AS (
  SELECT business_id, MIN(id) AS central_id
  FROM warehouses WHERE kind = 'central' AND status = 'active'
  GROUP BY business_id HAVING COUNT(*) = 1
), candidates AS (
  SELECT p.*, t.central_id
  FROM products p LEFT JOIN target t ON t.business_id = p.business_id
  WHERE (p.low_stock_level > 0 OR p.reorder_quantity > 0 OR
         (p.active AND p.track_inventory AND p.receive_low_stock_notification
          AND NOT EXISTS (SELECT 1 FROM product_warehouse_settings a JOIN warehouses aw ON aw.id = a.warehouse_id WHERE a.product_id = p.id AND aw.kind = 'central')))
    AND NOT EXISTS (SELECT 1 FROM products c WHERE c.parent_product_id = p.id)
), classified AS (
  SELECT c.business_id, c.id AS product_id,
         CASE
           WHEN c.central_id IS NULL                                        THEN 'unresolved_central'
           WHEN s.id IS NOT NULL AND s.status = 'inactive'                  THEN 'inactive_conflict'
           WHEN s.id IS NOT NULL AND s.low_stock_level = c.low_stock_level
                               AND s.reorder_quantity = c.reorder_quantity  THEN 'matching'
           WHEN s.id IS NOT NULL                                            THEN 'differing'
           WHEN NOT c.active                                                THEN 'archived'
           WHEN NOT c.track_inventory                                       THEN 'untracked'
           WHEN c.low_stock_level = 0 AND c.reorder_quantity = 0                THEN 'legacy_alert_only'
           ELSE 'to_create'
         END AS category,
         c.low_stock_level = 0 AND c.reorder_quantity > 0 AS reorder_only,
         (c.active AND c.track_inventory AND c.receive_low_stock_notification
          AND NOT EXISTS (SELECT 1 FROM product_warehouse_settings a JOIN warehouses aw ON aw.id = a.warehouse_id WHERE a.product_id = c.id AND aw.kind = 'central')) AS relies_on_legacy_alert,
         (c.receive_low_stock_notification AND c.low_stock_level > 0) AS central_alert_after
  FROM candidates c
  LEFT JOIN product_warehouse_settings s ON s.product_id = c.id AND s.warehouse_id = c.central_id
)
SELECT business_id, category,
       CASE category WHEN 'to_create' THEN 'pending transfer'
                     WHEN 'matching'  THEN 'transferred / already configured'
                     ELSE 'exception (not transferred; legacy alert, if any, kept)' END AS outcome,
       COUNT(*) AS products,
       COUNT(*) FILTER (WHERE reorder_only) AS of_which_reorder_only_threshold_0,
       COUNT(*) FILTER (WHERE category = 'to_create' AND relies_on_legacy_alert) AS legacy_alert_handed_over,
       COUNT(*) FILTER (WHERE category = 'to_create' AND relies_on_legacy_alert AND NOT central_alert_after) AS left_without_any_alert
FROM classified GROUP BY business_id, category ORDER BY business_id, category;

\echo '== 4b. Every candidate product: category, old values -> destination (to_create only)'
WITH target AS (
  SELECT business_id, MIN(id) AS central_id
  FROM warehouses WHERE kind = 'central' AND status = 'active'
  GROUP BY business_id HAVING COUNT(*) = 1
)
SELECT p.business_id, p.id AS product_id, p.sku,
       CASE
         WHEN t.central_id IS NULL                                        THEN 'unresolved_central'
         WHEN s.id IS NOT NULL AND s.status = 'inactive'                  THEN 'inactive_conflict'
         WHEN s.id IS NOT NULL AND s.low_stock_level = p.low_stock_level
                             AND s.reorder_quantity = p.reorder_quantity  THEN 'matching'
         WHEN s.id IS NOT NULL                                            THEN 'differing'
         WHEN NOT p.active                                                THEN 'archived'
         WHEN NOT p.track_inventory                                       THEN 'untracked'
         WHEN p.low_stock_level = 0 AND p.reorder_quantity = 0                THEN 'legacy_alert_only'
         ELSE 'to_create'
       END AS category,
       p.low_stock_level AS legacy_low, p.reorder_quantity AS legacy_reorder, p.reorder_level AS legacy_total_alert,
       p.receive_low_stock_notification AS legacy_notify,
       t.central_id AS destination_warehouse_id, s.status AS central_row_status,
       s.low_stock_level AS central_row_low, s.reorder_quantity AS central_row_reorder
FROM products p
LEFT JOIN target t ON t.business_id = p.business_id
LEFT JOIN product_warehouse_settings s ON s.product_id = p.id AND s.warehouse_id = t.central_id
WHERE (p.low_stock_level > 0 OR p.reorder_quantity > 0 OR
       (p.active AND p.track_inventory AND p.receive_low_stock_notification
        AND NOT EXISTS (SELECT 1 FROM product_warehouse_settings a JOIN warehouses aw ON aw.id = a.warehouse_id WHERE a.product_id = p.id AND aw.kind = 'central')))
  AND NOT EXISTS (SELECT 1 FROM products c WHERE c.parent_product_id = p.id)
ORDER BY p.business_id, category, p.id;

\echo '== 5. Conflicts in detail: differing Active rows and Inactive rows (never overwritten / reactivated)'
SELECT p.business_id, p.id AS product_id, p.sku, s.warehouse_id, s.status,
       p.low_stock_level AS legacy_low, s.low_stock_level AS row_low,
       p.reorder_quantity AS legacy_reorder, s.reorder_quantity AS row_reorder
FROM product_warehouse_settings s
JOIN warehouses w ON w.id = s.warehouse_id AND w.kind = 'central' AND w.status = 'active'
JOIN products p ON p.id = s.product_id
WHERE (p.low_stock_level > 0 OR p.reorder_quantity > 0)
  AND (s.status = 'inactive' OR s.low_stock_level <> p.low_stock_level OR s.reorder_quantity <> p.reorder_quantity)
ORDER BY p.business_id, p.id;

\echo '== 6. Legacy total alert today (reorder_level never mapped; level 0 still alerts when out of stock)'
SELECT p.business_id, (p.reorder_level > 0) AS level_set,
       COUNT(*) AS products,
       COUNT(*) FILTER (WHERE p.active AND p.track_inventory AND p.receive_low_stock_notification
                          AND NOT EXISTS (SELECT 1 FROM product_warehouse_settings s JOIN warehouses sw ON sw.id = s.warehouse_id WHERE s.product_id = p.id AND sw.kind = 'central'))
         AS currently_driving_total_alert,
       COUNT(*) FILTER (WHERE p.active AND p.track_inventory AND p.receive_low_stock_notification
                          AND EXISTS (SELECT 1 FROM product_warehouse_settings s WHERE s.product_id = p.id)
                          AND NOT EXISTS (SELECT 1 FROM product_warehouse_settings s JOIN warehouses sw ON sw.id = s.warehouse_id
                                          WHERE s.product_id = p.id AND sw.kind = 'central'))
         AS resumes_with_this_code_branch_rows_only,
       COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM product_warehouse_settings s JOIN warehouses sw ON sw.id = s.warehouse_id
                                      WHERE s.product_id = p.id AND sw.kind = 'central'))
         AS ended_by_a_central_row
FROM products p
WHERE NOT EXISTS (SELECT 1 FROM products c WHERE c.parent_product_id = p.id)
GROUP BY p.business_id, (p.reorder_level > 0) ORDER BY 1, 2;

\echo '== 7. Parent products with legacy values (never migrated) and branch rows (never touched)'
SELECT COUNT(*) AS parents_with_legacy_values FROM products p
WHERE (p.low_stock_level > 0 OR p.reorder_quantity > 0)
  AND EXISTS (SELECT 1 FROM products c WHERE c.parent_product_id = p.id);
SELECT COUNT(*) AS branch_rows FROM product_warehouse_settings s
JOIN warehouses w ON w.id = s.warehouse_id WHERE w.kind = 'branch';
