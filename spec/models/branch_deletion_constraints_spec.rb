require "rails_helper"

# BUG-026: OrganizationAccess::DeleteBranch lets the data model decide whether
# a branch has history. That is only safe while these hold — a schema or
# association change that breaks one must fail here, not silently re-open
# history deletion.
RSpec.describe "Branch deletion safety constraints (BUG-026)" do
  let(:conn) { ActiveRecord::Base.connection }
  let(:branch_foreign_keys) do
    conn.tables.flat_map { |table| conn.foreign_keys(table) }.select { |fk| fk.to_table == "branches" }
  end

  it "has a foreign key on every column that references a branch" do
    branch_columns = conn.tables.flat_map do |table|
      conn.columns(table).select { |column| column.name.end_with?("branch_id") }.map { |column| [ table, column.name ] }
    end
    keyed = branch_foreign_keys.map { |fk| [ fk.from_table, fk.column ] }

    expect(branch_columns - keyed).to be_empty
  end

  it "never cascades or nullifies a branch's rows in the database" do
    expect(branch_foreign_keys.map(&:on_delete).uniq).to eq([ nil ])
  end

  it "destroys nothing but configuration through Branch's associations" do
    destructive = Branch.reflect_on_all_associations.select do |reflection|
      %i[destroy delete_all destroy_async nullify].include?(reflection.options[:dependent])
    end

    # The supplying-warehouse link is reporting configuration, not history.
    expect(destructive.map(&:name)).to contain_exactly(:warehouse_supply)
  end
end
