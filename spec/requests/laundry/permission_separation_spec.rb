require "rails_helper"

# Verifies the Laundry Operations permissions are genuinely independent —
# each protects exactly one action, and none is sufficient to perform the
# others. This is the authorization-separation matrix required after
# simplifying the permission set to view_towel_balances / create_towel_transfers
# / confirm_towel_receipt / adjust_towel_balances / configure_towel_usage_expectations.
RSpec.describe "Laundry permission separation", type: :request do
  let(:business)        { create(:business) }
  let(:sales_branch)    { create(:branch, business: business, branch_type: "sales") }
  let(:laundry_branch)  { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type)      { business.towel_types.create!(name: "Bath Towel") }
  let(:owner)           { create(:user, :owner, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(4)}", permissions: perms,
      permission_scopes: perms.index_with { "business" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def fund(branch, status, quantity, actor:)
    Laundry::TowelAdjuster.new(actor: actor).call(
      towel_type: towel_type, branch: branch, status: status, adjustment_quantity: quantity, reason: "test setup"
    )
  end

  def dispatched_transfer(quantity: 100)
    transfer = business.towel_transfers.create!(towel_type: towel_type, source_branch: sales_branch,
                                                destination_branch: laundry_branch, towel_status: "dirty",
                                                declared_quantity: quantity)
    Laundry::TowelTransferCreator.new(transfer).dispatch(actor: owner)
    transfer
  end

  it "lets a user with only view_towel_balances view balances but not create a transfer" do
    viewer = user_with("view_towel_balances")
    sign_in viewer

    get laundry_towel_balances_path
    expect(response).to have_http_status(:ok)

    get new_laundry_towel_transfer_path
    expect(response).to redirect_to(root_path)
  end

  it "lets a user with create_towel_transfers create and dispatch, but not confirm receipt without confirm_towel_receipt" do
    creator = user_with("view_towel_balances", "create_towel_transfers")
    fund(sales_branch, "clean", 100, actor: owner)
    transfer = business.towel_transfers.create!(towel_type: towel_type, source_branch: sales_branch,
                                                destination_branch: laundry_branch, towel_status: "dirty",
                                                declared_quantity: 100)
    sign_in creator

    patch mark_dispatched_laundry_towel_transfer_path(transfer)
    expect(transfer.reload).to be_dispatched

    patch receive_laundry_towel_transfer_path(transfer), params: { confirmed_quantity: 100 }

    expect(transfer.reload).to be_dispatched # unchanged — request was denied
    expect(transfer.confirmed_quantity).to be_nil
    expect(transfer.received_by_id).to be_nil
    expect(transfer.received_at).to be_nil
  end

  it "lets a user with confirm_towel_receipt confirm receipt but not perform towel adjustments" do
    receiver = user_with("view_towel_balances", "confirm_towel_receipt")
    fund(sales_branch, "clean", 100, actor: owner)
    transfer = dispatched_transfer
    sign_in receiver

    patch receive_laundry_towel_transfer_path(transfer), params: { confirmed_quantity: 100 }
    expect(transfer.reload).to be_received

    get new_laundry_towel_adjustment_path
    expect(response).to redirect_to(root_path)

    post laundry_towel_adjustments_path, params: {
      towel_adjustment: { branch_id: laundry_branch.id, towel_type_id: towel_type.id,
                          status: "dirty", adjustment_quantity: -5, reason: "test" }
    }
    expect(response).to redirect_to(root_path)
  end

  it "lets a user with adjust_towel_balances record adjustments but not confirm receipts unless separately authorized" do
    adjuster = user_with("view_towel_balances", "adjust_towel_balances")
    fund(sales_branch, "clean", 200, actor: owner) # dispatch below consumes 100, leaving 100 for the adjustment
    transfer = dispatched_transfer
    sign_in adjuster

    post laundry_towel_adjustments_path, params: {
      towel_adjustment: { branch_id: sales_branch.id, towel_type_id: towel_type.id,
                          status: "clean", adjustment_quantity: -5, reason: "recount" }
    }
    expect(response).to redirect_to(laundry_towel_adjustments_path)

    patch receive_laundry_towel_transfer_path(transfer), params: { confirmed_quantity: 100 }

    expect(transfer.reload).to be_dispatched # unchanged — request was denied
    expect(transfer.confirmed_quantity).to be_nil
  end

  it "rejects a direct HTTP receive request from a user without confirm_towel_receipt, leaving all records untouched" do
    no_receipt_user = user_with("view_towel_balances", "create_towel_transfers")
    fund(sales_branch, "clean", 100, actor: owner)
    transfer = dispatched_transfer
    ledger_count_before = TowelLedgerEntry.count
    audit_count_before = AuditLog.count
    sign_in no_receipt_user

    patch receive_laundry_towel_transfer_path(transfer), params: { confirmed_quantity: 100 }

    transfer.reload
    expect(transfer).to be_dispatched
    expect(transfer.confirmed_quantity).to be_nil
    expect(transfer.received_at).to be_nil
    expect(transfer.received_by_id).to be_nil
    expect(transfer.discrepancy).to be_nil
    expect(TowelLedgerEntry.count).to eq(ledger_count_before)
    expect(Laundry::TowelBalances.new(towel_type).at_branch(laundry_branch, "dirty")).to eq(0)
    expect(AuditLog.count).to eq(audit_count_before)
  end

  it "leaves Super Admin (owner) behavior unchanged — full access regardless of the permission registry" do
    fund(sales_branch, "clean", 100, actor: owner)
    transfer = dispatched_transfer
    sign_in owner

    patch receive_laundry_towel_transfer_path(transfer), params: { confirmed_quantity: 100 }
    expect(transfer.reload).to be_received

    get laundry_towel_balances_path
    expect(response).to have_http_status(:ok)

    post laundry_towel_adjustments_path, params: {
      towel_adjustment: { branch_id: laundry_branch.id, towel_type_id: towel_type.id,
                          status: "dirty", adjustment_quantity: -5, reason: "owner override" }
    }
    expect(response).to redirect_to(laundry_towel_adjustments_path)
  end
end
