# Stock transfers no longer post on creation: a transfer is a draft,
# submission reserves, and only approval posts the movements
# (Inventory::StockTransferApproval, through the internal StockTransferPoster).
#
# Specs that just need a POSTED transfer as a fixture (reports, ledgers,
# voiding, availability guards, …) — what `StockTransferPoster.new(t).call`
# used to give them — go through this TEST-ONLY helper. It takes the built
# (unsaved) transfer through draft -> pending_approval -> approved with the
# real model validations and the real internal poster (locks, valuation,
# Inactive-destination guard, reservation-aware availability, paired
# movements), all in one savepoint, dated `posted_on` (default: the
# transfer's transferred_on, or today). It applies no permission, warehouse
# reach or audit — there is no production equivalent; specs of the workflow
# itself call the Inventory::StockTransfer* services.
#
# Returns a Result with #ok? and #transfer, like the old poster; on failure
# nothing is written and the reasons are on transfer.errors.
module StockTransferHelpers
  PostedTransfer = Struct.new(:ok, :transfer, keyword_init: true) do
    def ok? = ok
  end

  def post_stock_transfer(transfer, posted_on: nil)
    ok = false
    errors = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      transfer.status = :draft
      transfer.transferred_on ||= Date.current
      transfer.transfer_number ||= Inventory::NumberSequencer.new(transfer.business, :stock_transfer).next_number
      raise ActiveRecord::Rollback unless transfer.save

      transfer.status = :pending_approval
      raise ActiveRecord::Rollback unless transfer.save

      transfer.lock!
      day = posted_on || transfer.transferred_on
      unless Inventory::StockTransferPoster.new(transfer, posted_on: day).post!
        errors = transfer.errors.dup
        raise ActiveRecord::Rollback
      end

      transfer.status = :approved
      transfer.transferred_on = day
      transfer.save!
      ok = true
    end
    transfer.errors.merge!(errors) if errors
    PostedTransfer.new(ok: ok, transfer: transfer)
  end

  # A built transfer saved in `status` WITHOUT any stock effect — for policy
  # and screen specs that only care about the state. "approved" goes through
  # post_stock_transfer (an approved transfer always has its movements).
  def save_stock_transfer_in_status!(transfer, status, actor: nil)
    status = status.to_s
    return post_stock_transfer(transfer).tap { |r| raise "fixture post failed: #{transfer.errors.full_messages}" unless r.ok? }.transfer if status == "approved"

    transfer.status = :draft
    transfer.transferred_on ||= Date.current
    transfer.transfer_number ||= Inventory::NumberSequencer.new(transfer.business, :stock_transfer).next_number
    transfer.save!
    return transfer if status == "draft"

    if %w[pending_approval rejected].include?(status)
      transfer.update!(status: :pending_approval, submitted_by: actor, submitted_at: Time.current)
    end
    case status
    when "rejected"  then transfer.update!(status: :rejected, rejected_by: actor, rejected_at: Time.current, rejection_reason: "fixture")
    when "cancelled" then transfer.update!(status: :cancelled, cancelled_by: actor, cancelled_at: Time.current, cancellation_reason: "fixture")
    end
    transfer
  end
end

RSpec.configure { |config| config.include StockTransferHelpers }
