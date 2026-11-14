# Fixtures for Purchase Request advances.
#
# purchaser_with_custody — an employee eligible as a request's responsible
# employee or a funding source: the create_purchase_requests permission (one
# shared role per business) and an active custody account with `balance`.
#
# legacy_confirmed_advance — a CONFIRMED advance in the shape recorded before
# the funding workflow (2026-11-13): a supplier payment, with no recipient. The
# application can no longer create one (a legacy pending advance is never
# confirmed), but historical rows exist and must keep being applied at receiving
# and reversed. This writes exactly what that confirmation wrote: one
# FinancialSettlement on the request (the advance's financial_settlement) and,
# from custody, the linked "inventory_purchase" debit.
#
# old_pending_funding_advance — a funding advance still PENDING from the
# two-step workflow (before 2026-11-14 recording also posted the funding): the
# row as the old recorder left it — a recipient, no custody rows, no
# confirmation. The application no longer creates one; it may only be cancelled.
module PurchaseRequestAdvanceHelpers
  def purchaser_role_for(business)
    business.permission_roles.find_by(name: "Purchaser (spec)") ||
      business.permission_roles.create!(name: "Purchaser (spec)", permissions: %w[view_inventory create_purchase_requests])
  end

  def purchaser_with_custody(business, balance: 0, **user_attrs)
    user = create(:user, business: business, **user_attrs)
    user.update_column(:permission_role_id, purchaser_role_for(business).id)
    account = create(:custody_account, business: business, user: user, name: "#{user.first_name} Float")
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: balance) if balance.nonzero?
    account.refresh_balance!
    user
  end

  def custody_of(user) = CustodyAccount.find_by!(user: user)

  def legacy_confirmed_advance(request:, amount:, actor:, source_kind: "company_cash", custody_account: nil,
                               reference: nil, paid_on: Date.current)
    advance = request.advances.create!(business: request.business, amount: amount, source_kind: source_kind,
                                       custody_account: custody_account, paid_on: paid_on, reference: reference,
                                       created_by: actor)
    result = FinancialSettlementService.create(
      settleable: request, funding_source: custody_account, source_kind: source_kind,
      reference: reference.presence || request.request_number, amount: amount, actor: actor,
      notes: "Advance payment — Purchase Request #{request.request_number} (advance ##{advance.id})", settled_at: paid_on
    )
    raise result.error unless result.ok?

    if custody_account
      custody_account.custody_transactions.create!(
        business: request.business, txn_type: "inventory_purchase", amount: -amount, source: request,
        financial_settlement: result.settlement, created_by: actor, notes: "Advance payment (legacy)"
      )
      custody_account.refresh_balance!
    end
    advance.update!(status: "confirmed", confirmed_by: actor, confirmed_at: Time.current,
                    financial_settlement: result.settlement)
    advance
  end

  def old_pending_funding_advance(request:, amount:, actor:, source_kind: "company_cash", custody_account: nil)
    recipient = CustodyAccount.find_by!(user_id: request.responsible_employee_id)
    request.advances.create!(business: request.business, amount: amount, source_kind: source_kind,
                             custody_account: custody_account, recipient_custody_account: recipient,
                             paid_on: Date.current, created_by: actor)
  end
end

RSpec.configure { |config| config.include PurchaseRequestAdvanceHelpers }
