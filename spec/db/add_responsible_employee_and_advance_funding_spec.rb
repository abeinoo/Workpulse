require "rails_helper"
require Rails.root.join("db/migrate/20261113150000_add_responsible_employee_and_advance_funding")

# Schema regression guard for the responsible employee / advance funding
# columns. 20261113140000 (custody transfer) was applied on development before
# the design changed, so the funding shape is reached by 20261113150000 from
# that exact shape — never by rewriting an applied migration. These examples
# fail loudly if the database the app runs against lacks a column the code
# reads (the PR-page NoMethodError), if it drifts from db/schema.rb, or if the
# migration stops converting the 140000 shape. DDL runs inside the example's
# transaction (PostgreSQL DDL is transactional), so nothing persists.
RSpec.describe "AddResponsibleEmployeeAndAdvanceFunding" do
  let(:connection) { ActiveRecord::Base.connection }

  REQUIRED_COLUMNS = {
    "purchase_requests"         => %w[responsible_employee_id warehouse_id],
    "purchase_request_advances" => %w[recipient_custody_account_id funding_transaction_id funding_reversal_transaction_id]
  }.freeze

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { AddResponsibleEmployeeAndAdvanceFunding.new.migrate(direction) }
    [ PurchaseRequest, PurchaseRequestAdvance ].each(&:reset_column_information)
  end

  # Column names of one table as db/schema.rb declares them.
  def schema_rb_columns(table)
    block = File.read(Rails.root.join("db/schema.rb"))[/create_table "#{table}".*?\n  end\n/m]
    block.scan(/^\s+t\.\w+ "(\w+)"/).flatten
  end

  after { [ PurchaseRequest, PurchaseRequestAdvance ].each(&:reset_column_information) }

  describe "the migrated database" do
    it "has every column the application reads" do
      REQUIRED_COLUMNS.each do |table, columns|
        columns.each { |column| expect(connection.column_exists?(table, column)).to be(true), "#{table}.#{column} is missing" }
      end
      expect(PurchaseRequest.column_names).to include("responsible_employee_id")
      expect(PurchaseRequestAdvance.column_names).to include("funding_transaction_id", "funding_reversal_transaction_id")
      expect(PurchaseRequestAdvance.column_names).not_to include("custody_transfer_id", "custody_transfer_reversal_id")
    end

    it "matches db/schema.rb for both tables (no drift), with nothing pending" do
      REQUIRED_COLUMNS.each_key do |table|
        expect(connection.columns(table).map(&:name) - [ "id" ]).to eq(schema_rb_columns(table)) # id is implicit in schema.rb
      end
      expect(ActiveRecord::Base.connection_pool.migration_context.needs_migration?).to be(false)
      schema_version = File.read(Rails.root.join("db/schema.rb"))[/define\(version: ([\d_]+)\)/, 1].delete("_").to_i
      expect(schema_version).to eq(ActiveRecord::Base.connection_pool.migration_context.current_version)
    end

    it "keeps the funding links unique and pointing at custody_transactions, and the recipient check" do
      indexes = connection.indexes(:purchase_request_advances).to_h { |i| [ i.columns, i.unique ] }
      expect(indexes).to include([ "funding_transaction_id" ] => true, [ "funding_reversal_transaction_id" ] => true,
                                 [ "recipient_custody_account_id" ] => false)
      fks = connection.foreign_keys(:purchase_request_advances).to_h { |f| [ f.column, f.to_table ] }
      expect(fks).to include("funding_transaction_id" => "custody_transactions",
                             "funding_reversal_transaction_id" => "custody_transactions",
                             "recipient_custody_account_id" => "custody_accounts")
      expect(connection.foreign_keys(:purchase_requests).to_h { |f| [ f.column, f.to_table ] })
        .to include("responsible_employee_id" => "users")
      expect(connection.check_constraints(:purchase_request_advances).map(&:name))
        .to include("pr_advances_recipient_differs_from_source")
    end
  end

  describe "from the original 20261113140000 (custody transfer) shape" do
    let(:business) { create(:business) }
    let(:account)  { create(:custody_account, business: business) }

    it "converts it to the funding shape, keeping any value and its foreign key" do
      txn = account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 10)
      advance = begin
        pr = business.purchase_requests.build(created_by: create(:user, business: business))
        pr.items.build(product: business.products.create!(name: "P", sku: "P-1"), quantity: 1, unit_price: 1)
        pr.save!
        pr.advances.create!(business: business, amount: 1, source_kind: "company_cash", paid_on: Date.current)
      end

      migrate(:down) # the shape development has
      expect(connection.column_exists?(:purchase_requests, :responsible_employee_id)).to be(false)
      expect(connection.column_exists?(:purchase_request_advances, :custody_transfer_id)).to be(true)
      connection.execute("UPDATE purchase_request_advances SET custody_transfer_id = #{txn.id} WHERE id = #{advance.id}")

      migrate(:up)
      expect(connection.column_exists?(:purchase_request_advances, :custody_transfer_id)).to be(false)
      expect(connection.select_value("SELECT funding_transaction_id FROM purchase_request_advances WHERE id = #{advance.id}"))
        .to eq(txn.id)
      expect(PurchaseRequestAdvance.find(advance.id).funding_transaction).to eq(txn)
      expect {
        connection.transaction(requires_new: true) do
          connection.execute("UPDATE purchase_request_advances SET funding_transaction_id = -1 WHERE id = #{advance.id}")
        end
      }.to raise_error(ActiveRecord::InvalidForeignKey)
      expect(PurchaseRequest.column_names).to include("responsible_employee_id")
    end

    it "is reversible: down restores the exact 140000 columns and index names" do
      migrate(:down)
      expect(connection.columns(:purchase_request_advances).map(&:name))
        .to include("custody_transfer_id", "custody_transfer_reversal_id")
      expect(connection.indexes(:purchase_request_advances).map(&:name))
        .to include("index_purchase_request_advances_on_custody_transfer_id", "idx_on_custody_transfer_reversal_id_b2b88cee79")

      migrate(:up)
      expect(connection.indexes(:purchase_request_advances).map(&:name))
        .to include("index_purchase_request_advances_on_funding_transaction_id",
                    "idx_on_funding_reversal_transaction_id_4f4bfae67c")
    end
  end
end
