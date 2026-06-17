class AddVendorReferenceToExpenses < ActiveRecord::Migration[8.1]
  # Free-text supplier-side reference (invoice / receipt number). Distinct from
  # reference_number, which stays the auto-generated internal document number
  # (EXP-000001) used for audit and traceability. Optional and not unique — two
  # expenses may legitimately cite the same supplier invoice.
  def change
    add_column :expenses, :vendor_reference, :string
  end
end
