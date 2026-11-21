module Inventory
  # Product availability per warehouse — Phase 1, unit 6.
  #
  # Stock never comes INTO a product/warehouse pair whose availability row is
  # Inactive. The posting services call this inside their own transaction,
  # before any movement is written:
  #
  #   GoodsReceiptPoster   goods_receipt IN    (refused; N6 exception below)
  #   StockTransferPoster  transfer_in   IN    (destination pair refused)
  #   AdjustmentPoster     opening_balance IN  (refused; covers the product importer)
  #
  # Everything else stays allowed: outgoing movements, stock counts, ordinary
  # adjustments (both signs — they record physical reality and already carry a
  # reason and an audit entry), voids and reversals (compensating entries), and
  # every Not Configured pair (no row: warn-only until Phase 6).
  #
  # N6 — purchase-request exception: a goods receipt line that fulfils a line
  # of a purchase request may still be received when BOTH the request and the
  # receipt itself were approved before the pair was deactivated, the receipt
  # lands in that request's own warehouse and the request is still receivable.
  # (Approval of a receipt into an already-Inactive pair is refused by
  # Inventory::GoodsReceiptApproval, so a receipt approved after the
  # deactivation can only exist from before this rule — it never qualifies.) Everything is read from the database under
  # this transaction's locks (never from params), and each such line needs an
  # actor and a fail-closed audit entry (GoodsReceiptPoster#audit_exceptions!).
  #
  # Concurrency: the pair rows are read with FOR SHARE in id order. A
  # deactivation (ProductAvailabilityManager locks the row FOR UPDATE) either
  # commits first — this read then waits and sees Inactive — or waits until
  # the posting commits. The posters lock their documents / products first and
  # this row last; deactivation locks only this row, so there is no lock cycle.
  class IncomingAvailabilityGuard
    # A goods receipt line admitted by the N6 exception.
    ExceptionLine = Struct.new(:item, :setting, :purchase_request, :purchase_request_item, keyword_init: true)

    def initialize(warehouse_id:, product_ids:)
      @warehouse_id = warehouse_id
      @product_ids  = Array(product_ids).compact.uniq.sort
    end

    # The Inactive availability rows among the given products in the warehouse,
    # keyed by product id. Locks every matching row (Active ones too) FOR SHARE.
    def inactive_settings
      @inactive_settings ||= begin
        unless ActiveRecord::Base.connection.transaction_open?
          raise ArgumentError, "#{self.class.name} must run inside the posting transaction"
        end

        if @warehouse_id.nil? || @product_ids.empty?
          {}
        else
          ProductWarehouseSetting.where(warehouse_id: @warehouse_id, product_id: @product_ids)
                                 .order(:id).lock("FOR SHARE").includes(:product, :warehouse).to_a
                                 .select(&:status_inactive?).index_by(&:product_id)
        end
      end
    end

    def blocked? = inactive_settings.any?

    # Adds one error per refused product to the document; true when anything
    # was refused. `settings` defaults to every Inactive pair.
    def refuse!(document, settings = inactive_settings.values)
      settings.each do |setting|
        document.errors.add(:base, :product_inactive_in_warehouse,
                            product: setting.product.name, warehouse: setting.warehouse.name)
      end
      settings.any?
    end

    # Goods receipts: splits the receipt's lines for Inactive pairs into those
    # the N6 exception admits and those it refuses. Returns
    # [exception_lines, refused_settings].
    def classify_receipt(receipt)
      return [ [], [] ] unless blocked?

      exceptions = []
      refused    = {}
      receipt.items.reject(&:marked_for_destruction?).each do |item|
        setting = inactive_settings[item.product_id]
        next if setting.nil?

        line = n6_exception_for(receipt, item, setting)
        if line
          exceptions << line
        else
          refused[setting.id] = setting
        end
      end
      [ exceptions, refused.values ]
    end

    private

    def n6_exception_for(receipt, item, setting)
      return nil if item.purchase_request_item_id.nil? || receipt.purchase_request_id.nil?

      request = PurchaseRequest.where(business_id: receipt.business_id).find_by(id: receipt.purchase_request_id)
      line    = request && PurchaseRequestItem.find_by(id: item.purchase_request_item_id, purchase_request_id: request.id)
      return nil if line.nil? || line.product_id != item.product_id

      deactivated_at = setting.status_changed_at
      qualifies = deactivated_at.present? &&
                  PurchaseRequest::RECEIVABLE_STATUSES.include?(request.status) &&
                  request.approved_at.present? && request.approved_at < deactivated_at &&
                  receipt.approval_status == "approved" &&
                  receipt.decided_at.present? && receipt.decided_at < deactivated_at &&
                  request.receiving_warehouse_id == receipt.warehouse_id &&
                  receipt.warehouse_id == setting.warehouse_id
      return nil unless qualifies

      ExceptionLine.new(item: item, setting: setting, purchase_request: request, purchase_request_item: line)
    end
  end
end
