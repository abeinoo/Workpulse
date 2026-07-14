module Laundry
  # Single entry point for the TowelTransfer lifecycle — mirrors
  # Finance::TillHandoverCreator's "single entry point" + explicit-accept
  # convention. No code should write to TowelTransfer or TowelLedgerEntry
  # directly to move towels between branches.
  #
  # create    — draft, no ledger impact.
  # dispatch  — draft -> dispatched. See #dispatch for exactly what gets
  #             posted; a normal transfer posts one OUT entry, a
  #             laundry-to-sales-branch return (wash_conversion?) also
  #             converts dirty stock into clean first.
  # receive   — dispatched -> received. Posts an IN ledger entry at the
  #             destination branch for the CONFIRMED quantity only, and only
  #             when confirmed_quantity <= declared_quantity — receiving more
  #             than was dispatched is rejected outright (no valid source for
  #             the extra stock) and posts nothing. Any shortfall is left as
  #             a (never-negative) discrepancy — an investigation signal only,
  #             never auto-classified as loss/damage and never auto-corrected.
  #             Recording an actual loss/damage is a separate, explicit action
  #             through Laundry::TowelAdjuster.
  # cancel    — draft -> cancelled (no ledger impact), or
  #             dispatched/received -> cancelled (posts a compensating entry
  #             for every ledger row this transfer posted — a reversal, never
  #             a mutation). Cancelling a *received* transfer is a
  #             service-level-only capability for correcting bad historical
  #             data (e.g. an over-receipt from before this validation
  #             existed) — TowelTransferPolicy#cancel? still only authorizes
  #             draft/dispatched over HTTP, so this path isn't exposed as a
  #             normal user action.
  #
  # Every transition row-locks the transfer so a concurrent dispatch/receive/
  # cancel on the same record can never both succeed.
  class TowelTransferCreator
    include AuditLoggable

    Result = Struct.new(:ok, :transfer, :error, keyword_init: true) { def ok? = ok }

    def self.create(actor:, params:)
      transfer = TowelTransfer.new(
        business:            actor.business,
        towel_type_id:       params[:towel_type_id],
        source_branch_id:    params[:source_branch_id],
        destination_branch_id: params[:destination_branch_id],
        towel_status:        params[:towel_status],
        declared_quantity:   params[:declared_quantity],
        notes:               params[:notes],
        created_by:          actor
      )

      if transfer.save
        service = new(transfer)
        service.send(:log, actor, "create")
        Result.new(ok: true, transfer: transfer)
      else
        Result.new(ok: false, transfer: transfer, error: transfer.errors.full_messages.to_sentence)
      end
    end

    def initialize(transfer)
      @transfer = transfer
    end

    def dispatch(actor:)
      result = nil
      @transfer.with_lock do
        unless @transfer.draft?
          result = Result.new(ok: false, error: I18n.t("laundry.towel_transfers.errors.not_dispatchable"))
          next
        end

        if @transfer.wash_conversion?
          consumed = @transfer.declared_quantity
          available = balances.at_branch(@transfer.source_branch, "dirty")
          if consumed > available
            result = Result.new(ok: false, error: I18n.t("laundry.towel_transfers.errors.insufficient_dirty_stock",
                                                          available: available.to_s))
            next
          end

          post_entry(direction: :out, status: "dirty", quantity: consumed, reason: "wash_input", actor: actor)
          post_entry(direction: :in, status: "clean", quantity: @transfer.declared_quantity, reason: "wash_output", actor: actor)
        else
          available = balances.at_branch(@transfer.source_branch, "clean")
          if @transfer.declared_quantity > available
            result = Result.new(ok: false, error: I18n.t("laundry.towel_transfers.errors.insufficient_clean_stock",
                                                          available: available.to_s))
            next
          end
        end

        # The transfer's own dispatch is always posted against the source's
        # CLEAN balance — a sales branch never tracks a separate "dirty held
        # here" balance in this model (see TowelTransfer's class comment),
        # and a laundry-origin return has already converted its dirty stock
        # into clean, above.
        post_entry(direction: :out, status: "clean", quantity: @transfer.declared_quantity,
                   reason: "towel_transfer_dispatch", actor: actor)

        @transfer.update!(status: :dispatched, dispatched_by: actor, dispatched_at: Time.current)
        log(actor, "dispatch")
        result = Result.new(ok: true, transfer: @transfer)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    def receive(actor:, confirmed_quantity:)
      result = nil
      @transfer.with_lock do
        unless @transfer.dispatched?
          result = Result.new(ok: false, error: I18n.t("laundry.towel_transfers.errors.not_receivable"))
          next
        end

        confirmed = confirmed_quantity.to_d
        if confirmed.negative?
          result = Result.new(ok: false, error: I18n.t("laundry.towel_transfers.errors.invalid_confirmed_quantity"))
          next
        end

        # Receiving more than was dispatched would create untracked stock
        # with no valid source — reject outright, before any ledger entry is
        # posted. (TowelTransfer also enforces this at the model layer as
        # defense in depth; this check exists so the rejection is explicit
        # and no entry is even attempted, rather than relying on the
        # transaction rollback from a failed #update!.)
        if confirmed > @transfer.declared_quantity
          result = Result.new(ok: false, error: I18n.t("laundry.towel_transfers.errors.confirmed_exceeds_declared",
                                                        declared: @transfer.declared_quantity.to_i.to_s))
          next
        end

        if confirmed.positive?
          TowelLedgerEntry.create!(
            business:    @transfer.business,
            towel_type:  @transfer.towel_type,
            branch:      @transfer.destination_branch,
            direction:   :in,
            status:      @transfer.towel_status,
            reason:      "towel_transfer_receipt",
            quantity:    confirmed,
            occurred_at: Time.current,
            source:      @transfer,
            created_by:  actor
          )
        end

        @transfer.update!(status: :received, received_by: actor, received_at: Time.current,
                          confirmed_quantity: confirmed)
        log(actor, "receive", metadata: { declared_quantity: @transfer.declared_quantity,
                                          confirmed_quantity: confirmed,
                                          discrepancy: @transfer.discrepancy })
        result = Result.new(ok: true, transfer: @transfer)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    def cancel(actor:, reason: nil)
      result = nil
      @transfer.with_lock do
        unless @transfer.draft? || @transfer.dispatched? || @transfer.received?
          result = Result.new(ok: false, error: I18n.t("laundry.towel_transfers.errors.not_cancellable"))
          next
        end

        unless @transfer.draft?
          # Reverse every ledger entry this transfer posted (dispatch-time
          # entries, plus the receive-time entry if it was already received)
          # — correct whether that's the simple one-entry dispatch, the
          # multi-entry wash conversion, or a full received transfer. Never
          # mutates the originals.
          @transfer.towel_ledger_entries.each do |entry|
            TowelLedgerEntry.create!(
              business:    entry.business,
              towel_type:  entry.towel_type,
              branch:      entry.branch,
              direction:   entry.direction_in? ? :out : :in,
              status:      entry.status,
              reason:      "reversal",
              quantity:    entry.quantity,
              occurred_at: Time.current,
              source:      @transfer,
              created_by:  actor
            )
          end
        end

        @transfer.update!(status: :cancelled, cancelled_by: actor, cancelled_at: Time.current,
                          cancellation_reason: reason)
        log(actor, "cancel", metadata: { reason: reason })
        result = Result.new(ok: true, transfer: @transfer)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def balances
      @balances ||= Laundry::TowelBalances.new(@transfer.towel_type)
    end

    def post_entry(direction:, status:, quantity:, reason:, actor:)
      TowelLedgerEntry.create!(
        business:    @transfer.business,
        towel_type:  @transfer.towel_type,
        branch:      @transfer.source_branch,
        direction:   direction,
        status:      status,
        reason:      reason,
        quantity:    quantity,
        occurred_at: Time.current,
        source:      @transfer,
        created_by:  actor
      )
    end

    def log(actor, action, metadata: {})
      log_audit(actor: actor, auditable: @transfer, action: action,
                metadata: metadata.merge(source_branch_id: @transfer.source_branch_id,
                                         destination_branch_id: @transfer.destination_branch_id))
    end
  end
end
