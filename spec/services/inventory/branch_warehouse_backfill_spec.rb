require "rails_helper"

# Warehouse Architecture — PR 4: Inventory::BranchWarehouseBackfill#plan
# (read-only). #execute needs a connection with no open transaction, so it is
# specified in branch_warehouse_backfill_execute_spec.rb (non-transactional);
# two-connection races live in
# spec/services/organization_access/branch_provisioning_concurrency_spec.rb.
#
# The fixture mirrors the audited data: an approved business with one
# unclassified, stock-holding warehouse, three sales branches and a laundry;
# a second (not approved) business with two sales branches.
RSpec.describe Inventory::BranchWarehouseBackfill do
  let!(:business)  { create(:business, name: "Gedo Salon") }
  let!(:demo)      { create(:business, name: "Al-Noor Group") }
  let!(:owner)     { create(:user, :owner, business: business) }
  let!(:demo_owner) { create(:user, :owner, business: demo) }
  let!(:legacy)    { business.warehouses.create!(name: "المخزن الرئيسي") } # kind NULL, as in the real data
  let!(:shubra)    { create(:branch, business: business, name: "صالون جدو - شارع شبرا", branch_type: "sales") }
  let!(:bulaq)     { create(:branch, business: business, name: "صالون جدو - الترعة البولاقية", branch_type: "sales") }
  let!(:nasr)      { create(:branch, business: business, name: "صالون جدو - مدينة نصر", branch_type: "sales") }
  let!(:laundry)   { create(:branch, business: business, name: "دراي كلين", branch_type: "laundry") }
  let!(:riyadh)    { create(:branch, business: demo, name: "Riyadh HQ", branch_type: "sales") }
  let!(:jeddah)    { create(:branch, business: demo, name: "Jeddah Branch", branch_type: "sales") }

  def plan(actor: owner, approved: [ business.id ]) = described_class.new(actor: actor, approved_business_ids: approved).plan
  def by_branch(**args) = plan(**args).index_by(&:branch_id)

  describe "#plan (read-only, the actor's business only)" do
    it "classifies the audited data exactly" do
      expect(by_branch.transform_values(&:status)).to eq(
        shubra.id => "READY", bulaq.id => "READY", nasr.id => "READY", laundry.id => "NOT_ELIGIBLE"
      )
      expect(by_branch[shubra.id]).to have_attributes(proposed_name: "صالون جدو - شارع شبرا – المخزن", existing_warehouse_id: nil,
                                                      business_name: "Gedo Salon", active: true)
      expect(by_branch[laundry.id].proposed_name).to be_nil
    end

    it "never plans or exposes another business's branches — not even when that business is listed as approved" do
      candidates = plan(approved: [ business.id, demo.id ])

      expect(candidates.map(&:business_id).uniq).to eq([ business.id ])
      expect(candidates.map(&:branch_name)).not_to include("Riyadh HQ", "Jeddah Branch")
      expect(candidates.map(&:business_name).uniq).to eq([ "Gedo Salon" ])
    end

    it "marks the actor's business REQUIRES_MANUAL_REVIEW when it is not approved" do
      expect(by_branch(approved: []).values_at(shubra.id, bulaq.id, nasr.id).map { |c| [ c.status, c.reason ] })
        .to all(eq([ "REQUIRES_MANUAL_REVIEW", "business not approved for this backfill" ]))
    end

    it "keeps the demo business REQUIRES_MANUAL_REVIEW for its own actor, without showing the other business" do
      candidates = plan(actor: demo_owner, approved: [ business.id ])

      expect(candidates.to_h { |c| [ c.branch_id, c.status ] }).to eq(riyadh.id => "REQUIRES_MANUAL_REVIEW", jeddah.id => "REQUIRES_MANUAL_REVIEW")
    end

    it "sends an inactive sales branch to manual review" do
      nasr.update_column(:active, false)
      expect(by_branch[nasr.id]).to have_attributes(status: "REQUIRES_MANUAL_REVIEW", reason: "inactive sales branch")
    end

    it "reports a name collision — whatever the colliding warehouse is — and never proposes reusing it" do
      business.warehouses.create!(name: "صالون جدو - مدينة نصر – المخزن", kind: "central")
      unclassified = business.warehouses.create!(name: "X")
      unclassified.update_columns(name: "صالون جدو - الترعة البولاقية – المخزن")

      expect(by_branch[nasr.id].status).to eq("NAME_COLLISION")
      expect(by_branch[bulaq.id]).to have_attributes(status: "NAME_COLLISION", name_taken_by_id: unclassified.id)
    end

    it "recognizes an existing valid branch warehouse and an inconsistent one" do
      existing = Inventory::WarehouseManager.new(actor: owner).create(kind: "branch", name: "Shubra own", branch_id: shubra.id).warehouse
      broken   = Inventory::WarehouseManager.new(actor: owner).create(kind: "branch", name: "Bulaq own", branch_id: bulaq.id).warehouse
      broken.update_columns(business_id: demo.id) # an impossible state, forced past every validation

      expect(by_branch[shubra.id]).to have_attributes(status: "ALREADY_PROVISIONED", existing_warehouse_id: existing.id)
      expect(by_branch[bulaq.id]).to have_attributes(status: "INCONSISTENT_STATE", existing_warehouse_id: broken.id)
    end

    it "writes nothing" do
      writes = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        writes << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)/i)
      end
      plan
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(writes).to be_empty
    end

    it "refuses an inactive actor" do
      owner.update_column(:active, false)
      expect { plan }.to raise_error(described_class::Refused, I18n.t("inventory.warehouses.backfill.errors.inactive_actor"))
    end

    it "refuses an actor who does not manage branches" do
      clerk = user_with_stock_permissions(business, :view_inventory)
      expect { plan(actor: clerk) }.to raise_error(described_class::Refused, I18n.t("inventory.warehouses.backfill.errors.not_authorized"))
    end
  end
end
