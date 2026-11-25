# Screen-level gates for Stock Transfers. The operation permissions come from
# Inventory::StockTransferAuthorization — the same rule every workflow service
# enforces itself — so a screen can never allow what its service refuses.
# Every write also needs the warehouses it acts on (checked here for an
# instance and again by the service — Inventory::WarehouseReach): both ends
# for creating, approving, editing, rejecting, cancelling and resolving; the
# SOURCE to dispatch; the DESTINATION to receive. Visibility (Scope) needs
# either end. `record` may be the class itself for a bare permission check, so
# status and warehouse guards only apply to an actual instance.
class StockTransferPolicy < ApplicationPolicy
  def index?  = permits?(:view)
  def show?   = index?

  # Create / edit / submit a draft.
  def create? = permits?(:create)
  def new?    = create?
  def update? = create? && instance_check { record.draft? && !record.voided? }
  def edit?   = update?
  def submit? = update?

  def approve?      = permits?(:approve)      && instance_check { pending? }
  def edit_pending? = permits?(:edit_pending) && instance_check { pending? }
  def reject?       = permits?(:reject)       && instance_check { pending? }
  def cancel?       = permits?(:cancel)       && instance_check { record.cancellable? }

  def dispatch? = permits?(:dispatch) && side_check(:source) { record.awaiting_dispatch? }
  def receive?  = permits?(:receive)  && side_check(:destination) { record.in_transit? }
  def resolve?  = permits?(:resolve)  && instance_check { record.discrepancy? }

  # The Transfers in Transit / Receiving workspace: anyone who dispatches,
  # receives or resolves (each list there is filtered by its own reach rule).
  def receiving? = permits?(:dispatch) || permits?(:receive) || permits?(:resolve)

  # The Transfer Approvals queue: approve_stock_transfers only (legacy broad
  # permissions never grant it). Which transfers it lists — both warehouses
  # reachable — is Inventory::PendingStockTransferApprovals.
  def approvals? = permits?(:approve)

  # Live source/destination figures for a transfer form or a pending transfer.
  def availability? = create? || permits?(:edit_pending) || permits?(:approve)

  # Drafts are cancelled, never deleted (audit-first).
  def destroy? = false

  # Voiding posts movements into BOTH warehouses (out of the destination, back
  # into the source), so the user must have access to both — not just to the
  # one endpoint that made the transfer visible to them (see Scope). The rule
  # is unchanged by the approval workflow (manage_inventory /
  # manage_stock_transfers); only an approved (posted) transfer has movements
  # to reverse. The class gate (record is the StockTransfer class) checks the
  # permission only.
  def void?
    return false unless Inventory::StockTransferAuthorization.permits_void?(user)
    return true unless record.is_a?(StockTransfer)

    record.approved? && both_warehouses_accessible?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      relation = scope.for_business(user.business)
      ids = user.inventory_warehouse_ids
      return relation if ids.nil?

      # A scoped user sees a transfer if EITHER endpoint is one of their warehouses.
      relation.where(source_warehouse_id: ids).or(relation.where(destination_warehouse_id: ids))
    end
  end

  private

  def permits?(operation) = Inventory::StockTransferAuthorization.permits?(user, operation)

  def pending? = record.pending_approval? && !record.voided?

  def instance_check
    return true unless record.is_a?(StockTransfer)

    both_warehouses_accessible? && yield
  end

  # One end only: :source (dispatch) or :destination (receipt).
  def side_check(side)
    return true unless record.is_a?(StockTransfer)
    return false unless record.business_id == user.business_id

    ids = user.inventory_warehouse_ids
    warehouse_id = side == :source ? record.source_warehouse_id : record.destination_warehouse_id
    (ids.nil? || ids.include?(warehouse_id)) && yield
  end

  # nil from inventory_warehouse_ids = every warehouse of the user's business;
  # otherwise both endpoints must be among the user's ids.
  def both_warehouses_accessible?
    return false unless record.business_id == user.business_id

    ids = user.inventory_warehouse_ids
    return true if ids.nil?

    ids.include?(record.source_warehouse_id) && ids.include?(record.destination_warehouse_id)
  end
end
