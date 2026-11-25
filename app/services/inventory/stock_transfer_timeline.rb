module Inventory
  # A transfer's activity timeline, built ONLY from durable records — its audit
  # entries (every workflow step writes one) and its append-only receipts and
  # resolutions — never inferred from its current state. In chronological
  # order; no queries here (the caller preloads audit_logs with actors and
  # receipts / resolutions with their people, lines and products).
  #
  # A transfer posted before the workflow existed (legacy, no audit entry of
  # its own) shows one "posted on creation" entry from its own created_at /
  # created_by — the record itself, labelled as such.
  class StockTransferTimeline
    Event = Struct.new(:type, :time, :actor, :detail, :lines, keyword_init: true)

    AUDIT_TYPES = {
      "create" => :created, "update" => :draft_edited, "submit_for_approval" => :submitted,
      "update_pending" => :edited, "approve" => :approved, "reject" => :rejected, "cancel" => :cancelled,
      "dispatch" => :dispatched, "void" => :voided, "post" => :posted
    }.freeze

    def initialize(transfer, audit_logs:, receipts: [], resolutions: [])
      @transfer    = transfer
      @audit_logs  = audit_logs
      @receipts    = receipts
      @resolutions = resolutions
    end

    def events
      events = @audit_logs.filter_map { |log| from_audit(log) }
      events.concat(@receipts.map { |receipt| from_receipt(receipt) })
      events.concat(@resolutions.group_by { |r| [ r.resolved_at, r.resolved_by_id, r.reason ] }.map { |_, group| from_resolutions(group) })
      if events.empty? && @transfer.legacy_posting?
        events << Event.new(type: :legacy_posted, time: @transfer.created_at, actor: @transfer.created_by)
      end
      events.sort_by { |event| event.time || Time.at(0) }
    end

    private

    def from_audit(log)
      type = AUDIT_TYPES[log.action]
      return unless type

      if type == :approved && log.metadata["posting_mode"] == "direct"
        type = :approved_posted
      end
      Event.new(type: type, time: log.created_at, actor: log.actor, detail: log.metadata["reason"],
                lines: lines_from_audit(log))
    end

    def lines_from_audit(log)
      lines = log.metadata["requested_lines"] || log.metadata["approved_lines"] || log.metadata["dispatched_lines"]
      lines ||= Array(log.changes_json["items"]).last if log.action.in?(%w[update update_pending])
      Array(lines).map { |l| { product_id: l["product_id"], quantity: l["quantity"] } }
    end

    def from_receipt(receipt)
      type = if receipt.closes_with_shortfall then :received_with_shortfall
      elsif final_receipt?(receipt) then :received_in_full
      else :received_partially
      end
      Event.new(type: type, time: receipt.received_at, actor: receipt.received_by, detail: receipt.notes,
                lines: receipt.lines.map { |l| { product_id: l.stock_transfer_item.product_id, quantity: QuantityFormat.plain(l.quantity) } })
    end

    def from_resolutions(group)
      first = group.first
      Event.new(type: :resolved, time: first.resolved_at, actor: first.resolved_by, detail: first.reason,
                lines: group.map do |r|
                  { product_id: r.stock_transfer_item.product_id, quantity: QuantityFormat.plain(r.quantity), kind: r.kind }
                end)
    end

    # The receipt that completed the transfer: the last one of a received
    # transfer that needed no resolution.
    def final_receipt?(receipt)
      @transfer.received? && @resolutions.empty? && receipt == @receipts.max_by { |r| [ r.received_at, r.id ] }
    end
  end
end
