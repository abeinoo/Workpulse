require "rails_helper"

# Laundry batch material consumption posts an OUT inventory movement, so the
# warehouse it draws from must be one the user may reach
# (User#inventory_warehouse_ids) — enforced in the controller (policy scope)
# and again in Laundry::LaundryBatchService#record_consumption before any
# movement is written. record_batch_consumption is no longer in the permission
# registry (owners only), but a role saved before its removal still holds it;
# such a role must not bypass warehouse scope either.
RSpec.describe "Laundry batch consumption — warehouse scope", type: :request do
  let(:business)       { create(:business) }
  let(:other_business) { create(:business) }
  let!(:owner)         { create(:user, :owner, business: business) }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type)     { business.towel_types.create!(name: "Bath Towel") }
  let!(:laundry_wh)    { business.warehouses.create!(name: "Laundry Warehouse") }
  let!(:nasr_wh)       { business.warehouses.create!(name: "Nasr City WH") }
  let!(:foreign_wh)    { other_business.warehouses.create!(name: "Foreign WH") }
  let!(:detergent) do
    business.products.create!(name: "Detergent", sku: "DET-1", unit_of_measure: "kg", initial_cost_price: 20, average_cost_price: 20)
  end

  let!(:batch) do
    [ laundry_wh, nasr_wh ].each do |warehouse|
      r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
      r.items.build(product: detergent, quantity: 50, unit_cost: 20)
      Inventory::GoodsReceiptPoster.new(r).call
    end
    created = Laundry::LaundryBatchService.create(actor: owner, laundry_branch_id: laundry_branch.id, towel_type_id: towel_type.id)
    batch = created.batch
    Laundry::LaundryBatchService.new(batch).start(actor: owner, input_quantity: 10)
    batch.reload.tap { |b| raise "batch not in progress" unless b.in_progress? }
  end

  # A role saved before the laundry batch permissions left the registry.
  def legacy_laundry_user(assigned_to: nil)
    role = business.permission_roles.create!(name: "Legacy laundry #{SecureRandom.hex(2)}", permissions: %w[view_towel_balances],
                                              permission_scopes: { "view_towel_balances" => "business" })
    role.update_columns(permissions: %w[view_towel_balances manage_laundry_batches record_batch_consumption complete_laundry_batches],
                        permission_scopes: { "view_towel_balances" => "business", "manage_laundry_batches" => "business" })
    user = create(:user, business: business)
    user.update_column(:permission_role_id, role.id)
    WarehouseAssignment.create!(user: user, warehouse: assigned_to) if assigned_to
    user
  end

  def consume(warehouse_id, quantity: 3)
    post laundry_laundry_batch_consumptions_path(batch), params: { product_id: detergent.id, warehouse_id: warehouse_id, quantity: quantity }
  end

  def consumption_movements = InventoryMovement.where(reason: "laundry_consumption")

  it "lets the owner consume from a warehouse of the business" do
    sign_in owner
    expect { consume(laundry_wh.id) }.to change { consumption_movements.where(warehouse: laundry_wh).count }.by(1)
    expect(response).to redirect_to(laundry_laundry_batch_path(batch))
    expect(flash[:notice]).to eq(I18n.t("laundry.batches.consumption_recorded"))
  end

  describe "a legacy laundry role assigned to the Laundry Warehouse only" do
    let(:user) { legacy_laundry_user(assigned_to: laundry_wh) }

    before { sign_in user }

    it "consumes from its own warehouse" do
      expect { consume(laundry_wh.id) }.to change { consumption_movements.where(warehouse: laundry_wh).count }.by(1)
    end

    it "is refused another warehouse of the business, with no movement written" do
      expect { consume(nasr_wh.id) }.not_to change(InventoryMovement, :count)
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
    end

    it "is refused another business's warehouse, with no movement written" do
      expect { consume(foreign_wh.id) }.not_to change(InventoryMovement, :count)
      expect(response).to redirect_to(root_path)
    end

    it "is refused an unknown warehouse id" do
      expect { consume(0) }.not_to change(InventoryMovement, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  it "refuses an unassigned legacy laundry role once the business is fail-closed" do
    user = legacy_laundry_user
    store_warehouse_access_fail_closed!(business, true)
    sign_in user
    expect { consume(laundry_wh.id) }.not_to change(InventoryMovement, :count)
    expect(response).to redirect_to(root_path)
  end

  it "keeps the legacy rule for an unassigned legacy laundry role in a legacy business" do
    sign_in legacy_laundry_user
    expect { consume(nasr_wh.id) }.to change { consumption_movements.where(warehouse: nasr_wh).count }.by(1)
  end

  describe "the service refuses on its own (console / other callers)" do
    let(:user) { legacy_laundry_user(assigned_to: laundry_wh) }

    def record(actor, warehouse)
      Laundry::LaundryBatchService.new(batch).record_consumption(actor: actor, warehouse: warehouse, product: detergent, quantity: 2)
    end

    it "refuses a warehouse outside the actor's scope before writing any movement" do
      result = nil
      expect { result = record(user, nasr_wh) }.not_to change(InventoryMovement, :count)
      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("laundry.batches.errors.warehouse_not_accessible"))
    end

    it "refuses another business's warehouse even for the owner" do
      expect { record(owner, foreign_wh) }.not_to change(InventoryMovement, :count)
    end

    it "refuses an actor of another business" do
      foreign_owner = create(:user, :owner, business: other_business)
      expect { record(foreign_owner, laundry_wh) }.not_to change(InventoryMovement, :count)
    end

    it "records consumption from a warehouse in scope" do
      expect(record(user, laundry_wh)).to be_ok
    end
  end
end
