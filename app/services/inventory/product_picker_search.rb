module Inventory
  # The one product search behind every searchable product picker
  # (product-combobox): name, SKU or barcode, within an already-authorized
  # scope (ProductPolicy::Scope — business isolation) narrowed to the picker's
  # KIND, which mirrors the product list that picker always offered:
  #   transactable — inventory document lines, purchase requests, imports,
  #                  the dashboard search (Product.transactable);
  #   tracked      — branch comparison (active, inventory-tracked);
  #   all          — report filters that list every product (archived too).
  # Exact barcode / SKU matches come first, then names, alphabetically; at most
  # LIMIT rows, images and barcodes preloaded — the same few queries whatever
  # the catalogue size. Read-only.
  class ProductPickerSearch
    KINDS = {
      "transactable" => ->(scope) { scope.transactable },
      "tracked"      => ->(scope) { scope.active.inventory_tracked },
      "all"          => ->(scope) { scope }
    }.freeze
    LIMIT = 20

    def self.kind?(kind) = KINDS.key?(kind.to_s)

    def initialize(scope, kind:)
      @scope = KINDS.fetch(kind.to_s).call(scope)
    end

    def call(query)
      q = ProductBarcode.normalize(query).to_s # same trimming as stored / scanned barcodes
      relation = @scope.includes(:product_barcodes, :active_packaging_levels).with_primary_image
      return relation.order(:name, :id).limit(LIMIT).to_a if q.empty?

      like  = "%#{ActiveRecord::Base.sanitize_sql_like(q.downcase)}%"
      exact = q.downcase
      barcode_sql = "EXISTS (SELECT 1 FROM product_barcodes pb WHERE pb.product_id = products.id AND LOWER(pb.barcode) %s ?)"
      matches = ActiveRecord::Base.sanitize_sql_array(
        [ "LOWER(products.name) LIKE ? OR LOWER(products.sku) LIKE ? OR #{format(barcode_sql, 'LIKE')}", like, like, like ]
      )
      exact_first = ActiveRecord::Base.sanitize_sql_array(
        [ "CASE WHEN LOWER(products.sku) = ? OR #{format(barcode_sql, '=')} THEN 0 ELSE 1 END", exact, exact ]
      )
      relation.where(matches).order(Arel.sql(exact_first), :name, :id)
              .limit(LIMIT).to_a
    end
  end
end
