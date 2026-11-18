require "rails_helper"

# Warehouse Architecture — PR 1: warehouse kind (central / branch) and the
# owning branch of a branch warehouse. Model validations first, then the
# database constraints behind them (written with update_columns / insert_all,
# which skip validations, so the database is the only thing that can refuse).
RSpec.describe Warehouse, type: :model do
  let(:business)       { create(:business) }
  let(:other_business) { create(:business) }
  let(:sales_branch)   { create(:branch, business: business, branch_type: "sales") }

  def build_warehouse(**attrs)
    business.warehouses.build({ name: "Warehouse #{SecureRandom.hex(3)}" }.merge(attrs))
  end

  describe "model validations" do
    it "creates a central warehouse without a branch" do
      warehouse = build_warehouse(kind: "central")

      expect(warehouse).to be_valid
      expect { warehouse.save! }.to change(Warehouse, :count).by(1)
      expect(warehouse.reload).to be_kind_central
      expect(warehouse.branch).to be_nil
    end

    it "creates a branch warehouse for a sales branch of the same business" do
      warehouse = build_warehouse(kind: "branch", branch: sales_branch)

      expect(warehouse.save).to be(true)
      expect(warehouse.reload).to be_kind_branch
      expect(warehouse.branch).to eq(sales_branch)
    end

    it "rejects a branch warehouse without a branch" do
      warehouse = build_warehouse(kind: "branch")

      expect(warehouse).not_to be_valid
      expect(warehouse.errors.of_kind?(:branch, :blank)).to be(true)
      expect(warehouse.errors[:branch]).to include(I18n.t("activerecord.errors.messages.required"))
    end

    it "rejects a central warehouse with a branch" do
      warehouse = build_warehouse(kind: "central", branch: sales_branch)

      expect(warehouse).not_to be_valid
      expect(warehouse.errors.details[:branch]).to include(error: :only_for_branch_warehouse)
    end

    it "rejects a branch on a not-yet-classified warehouse" do
      warehouse = build_warehouse(kind: nil, branch: sales_branch)

      expect(warehouse).not_to be_valid
      expect(warehouse.errors.details[:branch]).to include(error: :only_for_branch_warehouse)
    end

    it "rejects a branch of another business" do
      foreign_branch = create(:branch, business: other_business, branch_type: "sales")
      warehouse = build_warehouse(kind: "branch", branch: foreign_branch)

      expect(warehouse).not_to be_valid
      expect(warehouse.errors.details[:branch]).to include(error: :other_business)
    end

    it "rejects a second branch warehouse for the same branch" do
      build_warehouse(kind: "branch", branch: sales_branch).save!
      second = build_warehouse(kind: "branch", branch: sales_branch)

      expect(second).not_to be_valid
      expect(second.errors.of_kind?(:branch_id, :taken)).to be(true)
      expect(second.errors[:branch_id])
        .to include(I18n.t("activerecord.errors.models.warehouse.attributes.branch_id.already_has_warehouse"))
    end

    %w[laundry headquarters maintenance warehouse other].each do |type|
      it "rejects a branch warehouse for a #{type} branch" do
        branch = create(:branch, business: business, branch_type: type)
        warehouse = build_warehouse(kind: "branch", branch: branch)

        expect(warehouse).not_to be_valid
        expect(warehouse.errors.details[:branch]).to include(error: :not_sales_branch)
      end
    end

    it "keeps a branch warehouse valid after its branch stops being a sales branch" do
      warehouse = build_warehouse(kind: "branch", branch: sales_branch)
      warehouse.save!
      sales_branch.update!(branch_type: "laundry")

      warehouse.reload.description = "still here"
      expect(warehouse).to be_valid
      expect(warehouse.save).to be(true)
    end

    it "allows several central warehouses in one business" do
      build_warehouse(kind: "central").save!
      second = build_warehouse(kind: "central")

      expect(second.save).to be(true)
      expect(business.warehouses.kind_central.count).to eq(2)
    end

    it "rejects an unknown kind without raising" do
      warehouse = build_warehouse(kind: "laundry")

      expect(warehouse).not_to be_valid
      expect(warehouse.errors.details[:kind]).to include(a_hash_including(error: :inclusion))
    end

    it "exposes kind scopes" do
      central  = build_warehouse(kind: "central").tap(&:save!)
      owned    = build_warehouse(kind: "branch", branch: sales_branch).tap(&:save!)
      unknown  = build_warehouse.tap(&:save!)

      expect(Warehouse.kind_central).to contain_exactly(central)
      expect(Warehouse.kind_branch).to contain_exactly(owned)
      expect(Warehouse.where(kind: nil)).to include(unknown)
    end
  end

  describe "compatibility with existing (unclassified) warehouses" do
    it "keeps creating a warehouse with no kind and no branch, exactly as before" do
      warehouse = business.warehouses.create!(name: "Legacy")

      expect(warehouse.kind).to be_nil
      expect(warehouse.branch_id).to be_nil
      expect(warehouse).to be_valid
    end

    it "keeps an unclassified warehouse editable and leaves its kind untouched" do
      warehouse = business.warehouses.create!(name: "Legacy")

      expect(warehouse.update(name: "Renamed", status: "inactive")).to be(true)
      expect(warehouse.reload.kind).to be_nil
    end
  end

  describe "database constraints" do
    let!(:warehouse) { business.warehouses.create!(name: "Raw") }

    it "refuses a branch warehouse without a branch" do
      expect { warehouse.update_columns(kind: "branch") }
        .to raise_error(ActiveRecord::StatementInvalid, /warehouses_branch_only_for_branch_kind/)
    end

    it "refuses a central warehouse with a branch" do
      expect { warehouse.update_columns(kind: "central", branch_id: sales_branch.id) }
        .to raise_error(ActiveRecord::StatementInvalid, /warehouses_branch_only_for_branch_kind/)
    end

    it "refuses a branch on an unclassified warehouse" do
      expect { warehouse.update_columns(branch_id: sales_branch.id) }
        .to raise_error(ActiveRecord::StatementInvalid, /warehouses_branch_only_for_branch_kind/)
    end

    it "refuses an unknown kind" do
      expect { warehouse.update_columns(kind: "laundry") }
        .to raise_error(ActiveRecord::StatementInvalid, /warehouses_kind_known/)
    end

    it "refuses a second warehouse for the same branch" do
      warehouse.update_columns(kind: "branch", branch_id: sales_branch.id)

      expect {
        Warehouse.insert_all!([ { business_id: business.id, name: "Dup", status: "active",
                                  kind: "branch", branch_id: sales_branch.id } ])
      }.to raise_error(ActiveRecord::RecordNotUnique, /index_warehouses_one_per_branch/)
    end

    it "allows several central and several unclassified warehouses" do
      expect {
        Warehouse.insert_all!([
          { business_id: business.id, name: "C1", status: "active", kind: "central" },
          { business_id: business.id, name: "C2", status: "active", kind: "central" },
          { business_id: business.id, name: "U1", status: "active", kind: nil }
        ])
      }.to change(Warehouse, :count).by(3)
    end

    it "refuses a branch id that does not exist" do
      expect { warehouse.update_columns(kind: "branch", branch_id: 0) }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "blocks deleting a branch that owns a warehouse" do
      warehouse.update_columns(kind: "branch", branch_id: sales_branch.id)

      # Savepoint: the FK violation must not abort the example's transaction.
      expect { Branch.transaction(requires_new: true) { Branch.where(id: sales_branch.id).delete_all } }
        .to raise_error(ActiveRecord::InvalidForeignKey)
      expect(warehouse.reload.branch_id).to eq(sales_branch.id)
    end
  end
end
