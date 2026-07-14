require "rails_helper"

RSpec.describe "Laundry towel transfers and batches", type: :request do
  let(:business) { create(:business) }
  let(:sales_branch)   { create(:branch, business: business, branch_type: "sales") }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let(:warehouse)  { business.warehouses.create!(name: "Laundry Warehouse") }

  def user_with(*perms, scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms,
                                              permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  # A real single-laundry business grants business-wide scope for these
  # permissions to laundry staff — they aren't branch managers of anything,
  # they just work at the one central laundry. Mirrors how an admin would
  # actually configure this role via the scope dropdown.
  let(:laundry_staff) do
    user_with("view_towel_balances", "create_towel_transfers", "confirm_towel_receipt",
              scopes: { "view_towel_balances" => "business", "create_towel_transfers" => "business",
                       "confirm_towel_receipt" => "business" })
  end
  let(:no_access_user) { create(:user, business: business) }

  def fund(branch, status, quantity)
    Laundry::TowelAdjuster.new(actor: laundry_staff).call(
      towel_type: towel_type, branch: branch, status: status, adjustment_quantity: quantity, reason: "test setup"
    )
  end

  it "denies access to the laundry module for a user with no laundry permissions" do
    sign_in no_access_user
    get laundry_root_path
    expect(response).to redirect_to(root_path)
  end

  it "only offers sales/laundry branches on the new transfer form's From/To selectors — not warehouse, headquarters, maintenance, or other" do
    sales_branch
    laundry_branch
    towel_type
    warehouse_branch    = create(:branch, business: business, branch_type: "warehouse", name: "Central Warehouse")
    headquarters_branch = create(:branch, business: business, branch_type: "headquarters", name: "HQ Office")
    maintenance_branch  = create(:branch, business: business, branch_type: "maintenance", name: "Repair Shop")
    other_branch        = create(:branch, business: business, branch_type: "other", name: "Misc Location")
    # assignable_branches only returns managed/area-managed branches for a
    # non-owner (see BranchScope#default_ids) — an owner sees every branch in
    # the business, which is what's needed to exercise the branch_type filter.
    owner = create(:user, :owner, business: business)
    sign_in owner

    get new_laundry_towel_transfer_path

    expect(response.body).to include(sales_branch.name, laundry_branch.name)
    expect(response.body).not_to include(warehouse_branch.name, headquarters_branch.name,
                                         maintenance_branch.name, other_branch.name)
  end

  it "runs the full transfer lifecycle: draft -> dispatch -> receive with a preserved discrepancy" do
    sign_in laundry_staff
    fund(sales_branch, "clean", 100)

    post laundry_towel_transfers_path, params: {
      towel_transfer: { towel_type_id: towel_type.id, source_branch_id: sales_branch.id,
                        destination_branch_id: laundry_branch.id, towel_status: "dirty", declared_quantity: 100 }
    }
    transfer = TowelTransfer.last
    expect(response).to redirect_to(laundry_towel_transfer_path(transfer))
    expect(transfer).to be_draft

    patch mark_dispatched_laundry_towel_transfer_path(transfer)
    expect(transfer.reload).to be_dispatched

    patch receive_laundry_towel_transfer_path(transfer), params: { confirmed_quantity: 98 }
    transfer.reload
    expect(transfer).to be_received
    expect(transfer.discrepancy).to eq(2)

    get laundry_towel_transfer_path(transfer)
    expect(response.body).to include("2") # discrepancy surfaced on the show page
  end

  it "runs the full laundry->branch return (wash conversion) through the actual HTTP/controller stack, with no loss fields" do
    sign_in laundry_staff
    fund(laundry_branch, "dirty", 50)

    post laundry_towel_transfers_path, params: {
      towel_transfer: { towel_type_id: towel_type.id, source_branch_id: laundry_branch.id,
                        destination_branch_id: sales_branch.id, declared_quantity: 50 }
    }
    transfer = TowelTransfer.last
    expect(response).to redirect_to(laundry_towel_transfer_path(transfer))
    expect(transfer.towel_status).to eq("clean") # server-inferred, not client-supplied

    patch mark_dispatched_laundry_towel_transfer_path(transfer)
    expect(transfer.reload).to be_dispatched
    expect(Laundry::TowelBalances.new(towel_type).at_branch(laundry_branch, "dirty")).to eq(0)

    patch receive_laundry_towel_transfer_path(transfer), params: { confirmed_quantity: 50 }
    expect(transfer.reload).to be_received
    expect(Laundry::TowelBalances.new(towel_type).at_branch(sales_branch, "clean")).to eq(50)
  end

  it "does not create a lost/damaged ledger entry or a TowelAdjustment from a receipt discrepancy" do
    sign_in laundry_staff
    fund(sales_branch, "clean", 100)

    post laundry_towel_transfers_path, params: {
      towel_transfer: { towel_type_id: towel_type.id, source_branch_id: sales_branch.id,
                        destination_branch_id: laundry_branch.id, declared_quantity: 100 }
    }
    transfer = TowelTransfer.last
    patch mark_dispatched_laundry_towel_transfer_path(transfer)

    expect {
      patch receive_laundry_towel_transfer_path(transfer), params: { confirmed_quantity: 98 }
    }.not_to change(TowelAdjustment, :count)

    expect(Laundry::TowelBalances.new(towel_type).at_branch(laundry_branch, "lost")).to eq(0)
    expect(Laundry::TowelBalances.new(towel_type).at_branch(laundry_branch, "damaged")).to eq(0)
  end

  it "ignores a client-supplied towel_status when the branch combination is inferable" do
    sign_in laundry_staff
    fund(sales_branch, "clean", 100)

    # A tampered/incorrect client value ("clean") for a sales->laundry route —
    # the server must still classify it as "dirty".
    post laundry_towel_transfers_path, params: {
      towel_transfer: { towel_type_id: towel_type.id, source_branch_id: sales_branch.id,
                        destination_branch_id: laundry_branch.id, towel_status: "clean", declared_quantity: 10 }
    }

    expect(TowelTransfer.last.towel_status).to eq("dirty")
  end

  it "runs the full batch lifecycle: start -> consume material -> complete, with conservation enforced" do
    # manage_laundry_batches/record_batch_consumption/complete_laundry_batches
    # were removed from the permission registry (the LaundryBatch workflow is
    # legacy, not part of normal navigation) — only the owner can still reach
    # it, verifying the underlying model/controller/routes/data are preserved.
    owner = create(:user, :owner, business: business)
    sign_in owner

    detergent = business.products.create!(name: "Detergent", sku: "DET-1", unit_of_measure: "kg",
                                          initial_cost_price: 20, average_cost_price: 20)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: detergent, quantity: 50, unit_cost: 20)
    Inventory::GoodsReceiptPoster.new(receipt).call

    post laundry_laundry_batches_path, params: {
      laundry_batch: { laundry_branch_id: laundry_branch.id, towel_type_id: towel_type.id }
    }
    batch = LaundryBatch.last
    expect(response).to redirect_to(laundry_laundry_batch_path(batch))

    patch start_laundry_laundry_batch_path(batch), params: { input_quantity: 98 }
    expect(batch.reload).to be_in_progress

    post laundry_laundry_batch_consumptions_path(batch), params: {
      product_id: detergent.id, warehouse_id: warehouse.id, quantity: 3
    }
    expect(batch.consumptions.count).to eq(1)

    # Mismatched output is rejected (conservation invariant).
    patch complete_laundry_laundry_batch_path(batch), params: { output_clean_quantity: 90, damaged_quantity: 2, disposed_quantity: 1 }
    expect(batch.reload).to be_in_progress

    patch complete_laundry_laundry_batch_path(batch), params: { output_clean_quantity: 95, damaged_quantity: 2, disposed_quantity: 1 }
    expect(batch.reload).to be_completed

    get laundry_laundry_batch_path(batch)
    expect(response).to have_http_status(:ok)
  end

  it "scopes a branch manager to only their managed branch's transfers" do
    role = business.permission_roles.create!(
      name: "Branch Mgr #{SecureRandom.hex(3)}",
      permissions: %w[view_towel_balances create_towel_transfers confirm_towel_receipt],
      permission_scopes: { "view_towel_balances" => "branch" }
    )
    manager = create(:user, business: business)
    manager.update_column(:permission_role_id, role.id)
    laundry_branch.update!(branch_manager_id: manager.id)

    own_transfer = business.towel_transfers.create!(
      towel_type: towel_type, source_branch: sales_branch, destination_branch: laundry_branch,
      towel_status: "dirty", declared_quantity: 10
    )

    other_branch = create(:branch, business: business, branch_type: "sales")
    another_branch = create(:branch, business: business, branch_type: "sales")
    unmanaged_transfer = business.towel_transfers.create!(
      towel_type: towel_type, source_branch: other_branch, destination_branch: another_branch,
      towel_status: "dirty", declared_quantity: 10
    )

    sign_in manager
    visible_ids = TowelTransferPolicy::Scope.new(manager, TowelTransfer).resolve.pluck(:id)
    expect(visible_ids).to include(own_transfer.id)
    expect(visible_ids).not_to include(unmanaged_transfer.id)

    get laundry_towel_transfers_path
    expect(response).to have_http_status(:ok)
  end
end
