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

  describe ".name_lock_key (the per-name advisory lock behind the uniqueness check)" do
    let(:conn) { ActiveRecord::Base.connection }

    def db_lower(name) = conn.select_value("SELECT LOWER(#{conn.quote(name)})")

    it "gives every name the database's LOWER() folds together the same key, and nothing else" do
      names = [ "Main", "MAIN", "main", "ÄRZTE Lager", "Ärzte lager", "ärzte lager", "المخزن الرئيسي", "Shubra – المخزن", "SHUBRA – المخزن" ]
      by_lower = names.group_by { |name| db_lower(name) }

      by_lower.each_value do |equal_names|
        expect(equal_names.map { |name| described_class.name_lock_key(business.id, name) }.uniq.size).to eq(1), equal_names.inspect
      end
      expect(by_lower.values.map { |group| described_class.name_lock_key(business.id, group.first) }.uniq.size).to eq(by_lower.size)
    end

    it "keeps businesses apart and does not strip the name (the validation does not either)" do
      expect(described_class.name_lock_key(business.id, "Main")).not_to eq(described_class.name_lock_key(other_business.id, "Main"))
      expect(described_class.name_lock_key(business.id, "Main ")).not_to eq(described_class.name_lock_key(business.id, "Main"))
    end
  end

  # The lock statements are parameterized as a whole (sanitize_sql_array over a
  # constant template), never built by interpolating SQL text — and they stay
  # exactly the statements the key definition describes.
  describe "the name lock statements (parameterized)" do
    let(:conn) { ActiveRecord::Base.connection }
    let(:tricky_names) do
      [ "O'Brien", "x'); SELECT pg_sleep(10); --", "a\\b", "x?y", ":name", "%_", "''", "line\nbreak", "المخزن الرئيسي" ]
    end

    it "lock exactly the key .name_lock_key_sql defines, values quoted, for any name" do
      tricky_names.each do |name|
        expect(described_class.name_lock_statement(business.id, name))
          .to eq("SELECT pg_advisory_xact_lock(#{described_class.name_lock_key_sql(business.id, name)})"), name.inspect
        expect(described_class.name_lock_key_sql(business.id, name)).to include(conn.quote(name)), name.inspect
      end
    end

    it "refuses a business id that is not an integer" do
      expect { described_class.name_lock_statement("1; DROP TABLE warehouses", "Main") }.to raise_error(ArgumentError)
    end

    it "takes, on save, exactly that statement — holding the advisory lock .name_lock_key reports" do
      name = "O'Brien – المخزن"
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
      held = described_class.transaction do
        business.warehouses.create!(name: name)
        conn.select_rows("SELECT classid::bigint, objid::bigint FROM pg_locks " \
                         "WHERE locktype = 'advisory' AND objsubid = 2 AND pid = pg_backend_pid()")
      end
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(statements).to include(described_class.name_lock_statement(business.id, name))
      # A two-int4 advisory lock shows its keys as unsigned oids in pg_locks.
      expect(held.map { |pair| pair.map(&:to_i) }).to include(described_class.name_lock_key(business.id, name).map { |k| k & 0xFFFFFFFF })
    end

    it "saves names with quotes and SQL metacharacters as plain data, uniqueness unchanged" do
      tricky_names.each { |name| business.warehouses.create!(name: name) }

      expect(business.warehouses.pluck(:name)).to match_array(tricky_names)
      duplicate = business.warehouses.new(name: "O'BRIEN")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
      expect(other_business.warehouses.new(name: "O'Brien")).to be_valid
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

  # Warehouses index type filter and branch display (read-only).
  describe "type filter scopes" do
    let!(:legacy)  { build_warehouse.tap(&:save!) }
    let!(:central) { build_warehouse(kind: "central").tap(&:save!) }
    let!(:owned)   { build_warehouse(kind: "branch", branch: sales_branch).tap(&:save!) }
    let!(:foreign) { other_business.warehouses.create!(name: "Foreign", kind: "central") }

    it "maps each supported filter to the stored kind exactly" do
      scope = business.warehouses
      expect(scope.for_kind_filter("central")).to contain_exactly(central)
      expect(scope.for_kind_filter("branch")).to contain_exactly(owned)
      expect(scope.for_kind_filter("unclassified")).to contain_exactly(legacy)
      expect(scope.unclassified).to contain_exactly(legacy)
    end

    it "returns everything for no filter or any unknown value" do
      [ nil, "", "all", "laundry", "Central", [ "central" ] ].each do |value|
        expect(business.warehouses.for_kind_filter(value)).to contain_exactly(legacy, central, owned)
      end
    end

    it "only narrows the relation it is given" do
      expect(Warehouse.where(business: business).for_kind_filter("central")).not_to include(foreign)
      expect(Warehouse::KIND_FILTERS).to eq(%w[central branch unclassified])
    end

    it "never changes a warehouse" do
      expect { business.warehouses.for_kind_filter("unclassified").to_a }.not_to(change { legacy.reload.attributes })
    end
  end

  describe "#owning_branch" do
    it "is the branch of a branch warehouse in the same business" do
      owned = build_warehouse(kind: "branch", branch: sales_branch).tap(&:save!)
      expect(owned.owning_branch).to eq(sales_branch)
    end

    it "is nil for central and unclassified warehouses" do
      expect(build_warehouse(kind: "central").owning_branch).to be_nil
      expect(build_warehouse.owning_branch).to be_nil
    end

    it "is nil for an inconsistent link to another business's branch" do
      owned = build_warehouse(kind: "branch", branch: sales_branch).tap(&:save!)
      owned.update_columns(branch_id: create(:branch, business: other_business, branch_type: "sales").id)
      expect(owned.reload.owning_branch).to be_nil
    end
  end
end
