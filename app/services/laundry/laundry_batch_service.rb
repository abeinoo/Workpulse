module Laundry
  # Single entry point for the LaundryBatch lifecycle: draft -> in_progress ->
  # completed (or cancelled). Completion posts the towel ledger entries and
  # enforces the input == output+damaged+disposed conservation check (see
  # LaundryBatch#conservation_balances). Reversal of a completed batch posts
  # compensating ledger entries and voids the batch — never mutates it.
  class LaundryBatchService
    include AuditLoggable

    Result = Struct.new(:ok, :batch, :error, keyword_init: true) { def ok? = ok }

    def self.create(actor:, laundry_branch_id:, towel_type_id:, operator_id: nil, notes: nil)
      batch = LaundryBatch.new(
        business:           actor.business,
        laundry_branch_id:  laundry_branch_id,
        towel_type_id:      towel_type_id,
        operator_id:        operator_id,
        notes:              notes,
        created_by:         actor
      )

      ActiveRecord::Base.transaction do
        batch.batch_number = BatchNumberSequencer.new(actor.business).next_number
        raise ActiveRecord::Rollback unless batch.save
      end

      if batch.persisted?
        Result.new(ok: true, batch: batch)
      else
        Result.new(ok: false, batch: batch, error: batch.errors.full_messages.to_sentence)
      end
    end

    def initialize(batch)
      @batch = batch
    end

    def start(actor:, input_quantity:)
      result = nil
      @batch.with_lock do
        unless @batch.draft?
          result = Result.new(ok: false, error: I18n.t("laundry.batches.errors.not_startable"))
          next
        end

        @batch.update!(status: :in_progress, started_at: Time.current, input_quantity: input_quantity)

        # Consumes dirty towels out of the laundry branch's balance immediately —
        # they are physically committed to this batch's wash cycle.
        TowelLedgerEntry.create!(
          business:    @batch.business,
          towel_type:  @batch.towel_type,
          branch:      @batch.laundry_branch,
          direction:   :out,
          status:      :dirty,
          reason:      "wash_input",
          quantity:    input_quantity,
          occurred_at: Time.current,
          source:      @batch,
          created_by:  actor
        )

        log(actor, "start")
        result = Result.new(ok: true, batch: @batch)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    def record_consumption(actor:, warehouse:, product:, quantity:)
      return Result.new(ok: false, error: I18n.t("laundry.batches.errors.not_in_progress")) unless @batch.in_progress?

      outcome = BatchMaterialConsumer.new(@batch, warehouse).call(product: product, quantity: quantity)
      return Result.new(ok: false, error: outcome.error) unless outcome.ok?

      log(actor, "record_consumption", metadata: { product_id: product.id, quantity: quantity.to_s })
      Result.new(ok: true, batch: @batch)
    end

    def complete(actor:, output_clean_quantity:, damaged_quantity: 0, disposed_quantity: 0)
      result = nil
      @batch.with_lock do
        unless @batch.in_progress?
          result = Result.new(ok: false, error: I18n.t("laundry.batches.errors.not_completable"))
          next
        end

        @batch.output_clean_quantity = output_clean_quantity
        @batch.damaged_quantity      = damaged_quantity
        @batch.disposed_quantity     = disposed_quantity

        unless @batch.valid?
          result = Result.new(ok: false, error: @batch.errors.full_messages.to_sentence)
          next
        end

        ActiveRecord::Base.transaction do
          @batch.update!(status: :completed, completed_by: actor, completed_at: Time.current)
          post_output_entries(actor)
        end

        log(actor, "complete", metadata: { output_clean_quantity: output_clean_quantity,
                                           damaged_quantity: damaged_quantity,
                                           disposed_quantity: disposed_quantity })
        result = Result.new(ok: true, batch: @batch)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    # Reverses a completed batch: posts compensating entries for everything
    # produced/consumed and re-credits the dirty input, then voids the batch.
    # The batch itself is never mutated or destroyed (Voidable + immutable-in-
    # spirit; historical consumption/costs stay intact for audit).
    def reverse(actor:, reason:)
      result = nil
      @batch.with_lock do
        unless @batch.completed?
          result = Result.new(ok: false, error: I18n.t("laundry.batches.errors.not_reversible"))
          next
        end

        ActiveRecord::Base.transaction do
          reverse_output_entries(actor)

          TowelLedgerEntry.create!(
            business: @batch.business, towel_type: @batch.towel_type, branch: @batch.laundry_branch,
            direction: :in, status: :dirty, reason: "reversal", quantity: @batch.input_quantity,
            occurred_at: Time.current, source: @batch, created_by: actor
          )

          @batch.update!(voided_at: Time.current, voided_by: actor, void_reason: reason)
        end

        log(actor, "reverse", metadata: { reason: reason })
        result = Result.new(ok: true, batch: @batch)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def post_output_entries(actor)
      [ [ :clean, @batch.output_clean_quantity, "wash_output" ],
        [ :damaged, @batch.damaged_quantity, "damage" ],
        [ :disposed, @batch.disposed_quantity, "disposal" ] ].each do |status, quantity, reason|
        next unless quantity.to_d.positive?

        TowelLedgerEntry.create!(
          business: @batch.business, towel_type: @batch.towel_type, branch: @batch.laundry_branch,
          direction: :in, status: status, reason: reason, quantity: quantity,
          occurred_at: Time.current, source: @batch, created_by: actor
        )
      end
    end

    def reverse_output_entries(actor)
      [ [ :clean, @batch.output_clean_quantity ],
        [ :damaged, @batch.damaged_quantity ],
        [ :disposed, @batch.disposed_quantity ] ].each do |status, quantity|
        next unless quantity.to_d.positive?

        TowelLedgerEntry.create!(
          business: @batch.business, towel_type: @batch.towel_type, branch: @batch.laundry_branch,
          direction: :out, status: status, reason: "reversal", quantity: quantity,
          occurred_at: Time.current, source: @batch, created_by: actor
        )
      end
    end

    def log(actor, action, metadata: {})
      log_audit(actor: actor, auditable: @batch, action: action,
                metadata: metadata.merge(laundry_branch_id: @batch.laundry_branch_id))
    end
  end
end
