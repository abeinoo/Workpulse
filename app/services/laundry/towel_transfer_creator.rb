module Laundry
  # Single entry point for the TowelTransfer lifecycle — mirrors
  # Finance::TillHandoverCreator's "single entry point" + explicit-accept
  # convention. No code should write to TowelTransfer or TowelLedgerEntry
  # directly to move towels between branches.
  #
  # A transfer is one document with many towel-type line items (see
  # TowelTransferItem) — one approval flow, one dispatch, one receipt
  # confirmation, covering every line item at once.
  #
  # create    — draft, no ledger impact.
  # dispatch  — draft -> dispatched. Iterates every line item: a normal line
  #             posts one OUT entry, a laundry-to-sales-branch return
  #             (wash_conversion?) also converts dirty stock into clean first.
  #             Availability is checked per towel type (one line item's
  #             shortage aborts the whole dispatch — never a partial
  #             dispatch) before anything is posted.
  # receive   — dispatched -> received. Posts an IN ledger entry per line item
  #             at the destination branch for the CONFIRMED quantity only,
  #             and only when confirmed_quantity <= declared_quantity for that
  #             line — receiving more than was dispatched on any single line
  #             is rejected outright (no valid source for the extra stock) and
  #             posts nothing for the whole document. Any shortfall is left as
  #             a (never-negative) per-line discrepancy — an investigation
  #             signal only, never auto-classified as loss/damage and never
  #             auto-corrected. Recording an actual loss/damage is a separate,
  #             explicit action through Laundry::TowelAdjuster.
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
        business:              actor.business,
        source_branch_id:      params[:source_branch_id],
        destination_branch_id: params[:destination_branch_id],
        towel_status:          params[:towel_status],
        notes:                 params[:notes],
        items_attributes:      params[:items_attributes] || {},
        created_by:            actor
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

        unless dispatch_availability_ok?
          result = Result.new(ok: false, error: @transfer.errors.full_messages.to_sentence)
          next
        end

        @transfer.items.each { |item| dispatch_item(item, actor: actor) }

        @transfer.update!(status: :dispatched, dispatched_by: actor, dispatched_at: Time.current)
        log(actor, "dispatch")
        result = Result.new(ok: true, transfer: @transfer)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    # confirmed_quantities: { item_id => quantity } — one receipt confirmation
    # for the whole document, covering every line item at once.
    def receive(actor:, confirmed_quantities:)
      result = nil
      @transfer.with_lock do
        unless @transfer.dispatched?
          result = Result.new(ok: false, error: I18n.t("laundry.towel_transfers.errors.not_receivable"))
          next
        end

        parsed = {}
        @transfer.items.each do |item|
          confirmed = confirmed_quantities[item.id] || confirmed_quantities[item.id.to_s]
          confirmed = confirmed.to_d
          if confirmed.negative?
            result = Result.new(ok: false, error: I18n.t("laundry.towel_transfers.errors.invalid_confirmed_quantity"))
            break
          end
          # Receiving more than was dispatched would create untracked stock
          # with no valid source — reject outright, before any ledger entry
          # is posted for ANY line (all-or-nothing, matching one receipt
          # confirmation for the whole document). TowelTransferItem also
          # enforces this at the model layer as defense in depth.
          if confirmed > item.declared_quantity
            result = Result.new(ok: false, error: I18n.t("laundry.towel_transfers.errors.confirmed_exceeds_declared",
                                                          declared: item.declared_quantity.to_i.to_s))
            break
          end
          parsed[item] = confirmed
        end
        next if result

        parsed.each do |item, confirmed|
          if confirmed.positive?
            TowelLedgerEntry.create!(
              business:    @transfer.business,
              towel_type:  item.towel_type,
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
          item.update!(confirmed_quantity: confirmed)
        end

        @transfer.update!(status: :received, received_by: actor, received_at: Time.current)
        log(actor, "receive", metadata: { items: parsed.map { |item, confirmed|
                                            { towel_type_id: item.towel_type_id, declared_quantity: item.declared_quantity,
                                              confirmed_quantity: confirmed, discrepancy: item.reload.discrepancy }
                                          } })
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
          # entries for every line item, plus the receive-time entries if it
          # was already received) — correct whether that's a single line, a
          # multi-line document, a wash conversion, or a fully received
          # transfer. Never mutates the originals.
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

    # Checks every line item's availability before anything is posted —
    # mirrors Inventory::StockIssuePoster#availability_ok?'s aggregate
    # pattern: collect one error per failing line, abort the whole dispatch
    # if any line fails (all-or-nothing, never a partial dispatch).
    def dispatch_availability_ok?
      ok = true
      @transfer.items.each do |item|
        balances = Laundry::TowelBalances.new(item.towel_type)
        if @transfer.wash_conversion?
          available = balances.at_branch(@transfer.source_branch, "dirty")
          status = "dirty"
        else
          available = balances.at_branch(@transfer.source_branch, "clean")
          status = "clean"
        end

        next unless item.declared_quantity > available
        ok = false
        @transfer.errors.add(:base, :insufficient_stock, status: status, towel_type: item.towel_type.name,
                             available: available.to_s, requested: item.declared_quantity.to_s)
      end
      ok
    end

    def dispatch_item(item, actor:)
      balances = Laundry::TowelBalances.new(item.towel_type)

      if @transfer.wash_conversion?
        post_entry(towel_type: item.towel_type, direction: :out, status: "dirty", quantity: item.declared_quantity,
                   reason: "wash_input", actor: actor)
        post_entry(towel_type: item.towel_type, direction: :in, status: "clean", quantity: item.declared_quantity,
                   reason: "wash_output", actor: actor)
      end

      # The transfer's own dispatch is always posted against the source's
      # CLEAN balance — a sales branch never tracks a separate "dirty held
      # here" balance in this model (see TowelTransfer's class comment),
      # and a laundry-origin return has already converted its dirty stock
      # into clean, above.
      post_entry(towel_type: item.towel_type, direction: :out, status: "clean", quantity: item.declared_quantity,
                 reason: "towel_transfer_dispatch", actor: actor)
    end

    def post_entry(towel_type:, direction:, status:, quantity:, reason:, actor:)
      TowelLedgerEntry.create!(
        business:    @transfer.business,
        towel_type:  towel_type,
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
