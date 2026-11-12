module Inventory
  # Records counted quantities on a draft / in-progress stock count — the
  # single write path for counting (the counting screen and the CSV import).
  #
  # Decision D2 — each product's count carries its own time and baseline:
  # when a physical quantity is entered (or changed), the row records
  #   counted_at      = now
  #   system_quantity = the warehouse's ledger on-hand read at that moment
  #   quantity_source = "physical"
  # so difference = counted − on-hand at count time, and the approval posts
  # exactly that difference: receipts, issues, transfers and adjustments
  # committed after the count are preserved instead of being "corrected away".
  # Re-submitting an unchanged quantity keeps its original count time.
  #
  # Decisions D8/D9 — a legacy row (quantity entered before per-product count
  # times existed) is never treated as a physical count: a blank entry leaves
  # it untouched; a new entry is a physical recount, and the old unverified
  # quantity is preserved in legacy_counted_quantity. A system-derived row
  # (ledger quantity adopted at completion, visible again after a reopen) is
  # likewise kept as it is — source, baseline and time — when it comes back
  # blank or with its own quantity; only a different quantity makes it a
  # physical recount.
  #
  # entries: [{ id:, product_id:, counted_quantity:, original_counted_quantity: }]
  # — id names an existing row of this count; product_id alone adds a row
  # (barcode scanner / import). A client-supplied system quantity is never
  # accepted.
  #
  # The counting screen pre-fills each row with the last quantity a person
  # entered and saved, and sends that displayed value back as
  # original_counted_quantity. A row whose submitted quantity equals what was
  # displayed is UNCHANGED and is not touched at all — its quantity, source,
  # count time and baseline stay as they were — so resuming a count and saving
  # never creates a recount. Only a quantity the person actually changed is a
  # new physical count. Entries without original_counted_quantity (CSV import)
  # are compared with the stored row, as before.
  #
  # entered: true means the person typed in that row's field on the counting
  # screen. A typed quantity is ALWAYS a fresh physical count — new count time
  # and ledger baseline — even when it equals the previous (e.g. unverified
  # legacy) quantity; that is how a counter confirms "I counted 3". A blank
  # typed entry follows the blank rules below.
  #
  # The count row is locked, so a save racing with Complete either lands
  # before the cutoff or is refused.
  class StockCountRecorder
    include StockCountService

    NO_NOTES = Object.new.freeze

    # A row or quantity the request can't name (reported, nothing written).
    class InvalidEntry < StandardError; end

    def initialize(stock_count_id:, actor:, entries:, notes: NO_NOTES)
      @stock_count_id = stock_count_id
      @actor          = actor
      @entries        = Array(entries)
      @notes          = notes
    end

    def call
      ActiveRecord::Base.transaction do
        lock_count!
        return failure(t_error("not_editable")) unless @count.editable_counts?

        changes = record_entries!
        @count.notes = @notes unless @notes.equal?(NO_NOTES)
        started = start_counting
        @count.save!

        log_audit(actor: @actor, auditable: @count, action: "start_counting",
                  changes: { status: %w[draft in_progress] }) if started
        if changes.any?
          log_audit(actor: @actor, auditable: @count, action: "record_counts",
                    metadata: { count_number: @count.count_number, items: changes })
        end
      end
      success
    rescue ActiveRecord::RecordInvalid => e
      failure(record_error_message(e.record))
    rescue InvalidEntry => e
      failure(e.message)
    end

    # The rows touched by the last #call (for callers that report counts).
    def applied_count = @applied_count.to_i

    private

    def record_entries!
      by_id      = @count.items.index_by(&:id)
      by_product = @count.items.index_by(&:product_id)
      resolved   = @entries.reject { |entry| unchanged_on_screen?(entry) }
                           .map { |entry| [ resolve_item(entry, by_id, by_product), parse(entry[:counted_quantity]), entered?(entry) ] }
      on_hand    = on_hand_for(resolved.map { |item, *| item.product_id }.compact)
      now        = Time.current

      changes = resolved.filter_map do |item, quantity, entered|
        change = apply(item, quantity, on_hand[item.product_id].to_d, now, entered: entered)
        next unless change

        item.save!
        change
      end
      @applied_count = changes.size
      changes
    end

    def entered?(entry) = ActiveModel::Type::Boolean.new.cast(entry[:entered]) == true

    # The row came back exactly as the counting screen displayed it, untouched.
    def unchanged_on_screen?(entry)
      return false if entered?(entry) || !entry.key?(:original_counted_quantity)

      parse(entry[:original_counted_quantity]) == parse(entry[:counted_quantity])
    end

    def resolve_item(entry, by_id, by_product)
      if entry[:id].present?
        by_id.fetch(entry[:id].to_i) { raise InvalidEntry, t_error("unknown_row") }
      else
        product_id = entry[:product_id].to_i
        by_product[product_id] || @count.items.build(product_id: product_id).tap { |item| by_product[product_id] = item }
      end
    end

    # Returns the audit change for the row, or nil when nothing changed.
    def apply(item, quantity, on_hand, now, entered: false)
      if quantity.nil?
        # Blank never discards a legacy quantity (it simply was not recounted);
        # on any other row it clears the count.
        return nil if item.legacy_unverified? || item.system_derived? || !item.counted?

        change = audit_change(item, nil)
        item.assign_attributes(counted_quantity: nil, counted_at: nil, baseline_at: nil, quantity_source: nil)
        return change
      end

      unless entered
        return nil if (item.physical? || item.system_derived?) && item.counted_quantity.to_d == quantity
      end

      change = audit_change(item, quantity)
      item.legacy_counted_quantity = item.counted_quantity if item.legacy_unverified?
      item.assign_attributes(counted_quantity: quantity, counted_at: now, baseline_at: now,
                             system_quantity: on_hand, quantity_source: "physical")
      change.merge(system_quantity: quantity_string(on_hand))
    end

    def audit_change(item, quantity)
      { product_id: item.product_id,
        from: quantity_string(item.counted_quantity),
        from_source: item.quantity_source || (item.legacy_unverified? ? "legacy" : nil),
        to: quantity_string(quantity) }
    end

    def start_counting
      return false unless @count.draft?

      @count.status     = :in_progress
      @count.started_at = Time.current
      @count.created_by ||= @actor
      true
    end

    def parse(value)
      return nil if value.nil? || value.to_s.strip.empty?

      BigDecimal(value.to_s.strip)
    rescue ArgumentError, TypeError
      raise InvalidEntry, t_error("invalid_quantity", value: value.to_s.strip)
    end
  end
end
