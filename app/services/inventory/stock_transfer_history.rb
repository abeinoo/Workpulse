module Inventory
  # The Stock Transfers history list: the transfers a user may see
  # (StockTransferPolicy::Scope), narrowed by the page's filters. Read-only.
  #
  #   status       any stored status, or "partially_received" (derived: in
  #                transit with at least one receipt)
  #   q            transfer number, or a product name / SKU on any line
  #   source_warehouse_id / destination_warehouse_id
  #   person_id    requester, approver, dispatcher or a receiver
  #   from / to    the transfer date (the dispatch / posting day once moved)
  class StockTransferHistory
    FILTERS = %i[status q source_warehouse_id destination_warehouse_id person_id from to].freeze
    STATUS_FILTERS = (StockTransfer.statuses.keys + %w[partially_received]).freeze

    def initialize(scope, filters)
      @scope   = scope
      @filters = filters.to_h.symbolize_keys.slice(*FILTERS).transform_values { |v| v.to_s.strip }.reject { |_, v| v.empty? }
    end

    attr_reader :filters

    def active? = @filters.any?

    def relation
      rel = @scope
      rel = status_filter(rel)
      rel = rel.where(source_warehouse_id: @filters[:source_warehouse_id]) if @filters[:source_warehouse_id]
      rel = rel.where(destination_warehouse_id: @filters[:destination_warehouse_id]) if @filters[:destination_warehouse_id]
      rel = person_filter(rel) if @filters[:person_id]
      rel = rel.where(transferred_on: date(:from)..) if date(:from)
      rel = rel.where(transferred_on: ..date(:to)) if date(:to)
      rel = search(rel) if @filters[:q]
      rel
    end

    private

    def status_filter(rel)
      status = @filters[:status]
      return rel unless STATUS_FILTERS.include?(status)
      return rel.in_transit.where(id: StockTransferReceipt.select(:stock_transfer_id)) if status == "partially_received"

      rel.where(status: status)
    end

    def person_filter(rel)
      id = @filters[:person_id].to_i
      rel.where(created_by_id: id).or(rel.where(approved_by_id: id)).or(rel.where(dispatched_by_id: id))
         .or(rel.where(id: StockTransferReceipt.where(received_by_id: id).select(:stock_transfer_id)))
    end

    def search(rel)
      term = "%#{ActiveRecord::Base.sanitize_sql_like(@filters[:q])}%"
      with_product = StockTransferItem.joins(:product)
                                      .where("products.name ILIKE :t OR products.sku ILIKE :t", t: term)
                                      .select(:stock_transfer_id)
      rel.where("stock_transfers.transfer_number ILIKE ?", term).or(rel.where(id: with_product))
    end

    def date(key)
      Date.iso8601(@filters[key]) if @filters[key]
    rescue Date::Error
      nil
    end
  end
end
