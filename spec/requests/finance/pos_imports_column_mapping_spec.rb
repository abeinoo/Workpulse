require "rails_helper"

RSpec.describe "Finance::PosImports column mapping auto-detection", type: :request do
  let(:business) { create(:business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:importer) { user_with("manage_pos_import", "view_pos_transactions_verification", "view_daily_reconciliation") }

  def pos_import_with_headers(headers)
    extra_columns = headers.size - 5
    row = [ "2026-07-01", "Main", "Ahmed", "Cash", "100" ] + Array.new(extra_columns) { |i| "REF-#{i}" }
    csv = ([ headers.join(",") ] + [ row.join(",") ]).join("\n")
    pos_import = PosImport.create!(business: business, imported_by: importer, file_name: "export.csv", status: "pending")
    pos_import.file.attach(io: StringIO.new(csv), filename: "export.csv", content_type: "text/csv")
    pos_import
  end

  def reference_number_selected_option(body)
    doc = Nokogiri::HTML(body)
    select = doc.at_css("select[name='column_mapping[reference_number]']")
    select.at_css("option[selected]")&.text
  end

  describe "GET edit_column_mapping" do
    it "defaults Reference Number to 'Payment no.' when both 'Payment no.' and 'Appt. ref' columns exist" do
      pos_import = pos_import_with_headers(
        %w[Date Location Cashier Method Amount] + [ "Payment no.", "Appt. ref" ]
      )

      sign_in importer
      get edit_column_mapping_finance_pos_import_path(pos_import)

      expect(reference_number_selected_option(response.body)).to eq("Payment no.")
    end

    it "falls back to 'Appt. ref' when 'Payment no.' is absent" do
      pos_import = pos_import_with_headers(
        %w[Date Location Cashier Method Amount] + [ "Appt. ref" ]
      )

      sign_in importer
      get edit_column_mapping_finance_pos_import_path(pos_import)

      expect(reference_number_selected_option(response.body)).to eq("Appt. ref")
    end

    it "does not override a previously saved mapping" do
      pos_import = pos_import_with_headers(
        %w[Date Location Cashier Method Amount] + [ "Payment no.", "Appt. ref" ]
      )
      pos_import.update!(column_mapping: {
        "transaction_date" => "Date", "branch_name" => "Location", "cashier_name" => "Cashier",
        "payment_method_name" => "Method", "amount" => "Amount", "reference_number" => "Appt. ref"
      })

      sign_in importer
      get edit_column_mapping_finance_pos_import_path(pos_import)

      expect(reference_number_selected_option(response.body)).to eq("Appt. ref")
    end
  end
end
