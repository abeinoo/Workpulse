require "rails_helper"

RSpec.describe "Finance::DailyReconciliations show — POS Transactions Verification", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer)    { user_with("view_daily_reconciliation", "view_pos_transactions_verification") }
  let(:importer)  { user_with("view_daily_reconciliation", "view_pos_transactions_verification", "manage_pos_import") }
  let(:no_perm)   { user_with("view_daily_reconciliation") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session)  { TillSession.create!(daily_reconciliation: dr, depositor_id: viewer.id) }
  let!(:session_amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 500, refund_amount: 0)
  end

  def create_pos_transaction!(cashier: "Ahmed", amount: 500, payment_method_name: "Cash")
    pos_import = PosImport.create!(business: business, imported_by: viewer, file_name: "export.csv", status: "imported")
    PosTransaction.create!(
      business: business, pos_import: pos_import, daily_reconciliation: dr,
      transaction_date: Date.current, cashier_name: cashier, branch_name: branch.name,
      payment_method_name: payment_method_name, amount: amount
    )
  end

  describe "section visibility" do
    it "shows the POS Transactions Verification section for a user with the permission" do
      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(I18n.t("finance.pos_imports.verification.title"))
    end

    it "does not show the section for a user without the permission, even with view_daily_reconciliation" do
      sign_in no_perm
      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include(I18n.t("finance.pos_imports.verification.title"))
    end

    it "hides POS comparison data even when POS transactions exist for the DR" do
      create_pos_transaction!

      sign_in no_perm
      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include(I18n.t("finance.pos_imports.verification.title"))
      expect(response.body).not_to include(I18n.t("finance.pos_imports.verification.branch_totals_title"))
      expect(response.body).not_to include(I18n.t("finance.daily_reconciliations.show.collected_pos_total"))
    end

    it "shows the Session Totals comparison for a permissioned user once POS data exists" do
      card_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: card_pm, payment_method_name: "Visa",
                                collected_amount: 500, refund_amount: 0)
      create_pos_transaction!(payment_method_name: "Visa")

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.session_totals_title"))
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.col_workpulse_total"))
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.col_pos_total"))
      expect(response.body).to include(I18n.t("finance.pos_imports.verification.status_verified"))
      expect(response.body).to include("Visa")
    end

    it "always shows the WorkPulse Session Totals, even before any POS import" do
      card_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: card_pm, payment_method_name: "Visa",
                                collected_amount: 300, refund_amount: 0)

      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.session_totals_title"))
      expect(response.body).to include(I18n.t("finance.pos_imports.verification.status_not_imported"))
      expect(response.body).to include("Visa")
    end

    it "shows the Employee Details breakdown with WorkPulse vs Imported POS per employee" do
      cashier_role = business.permission_roles.create!(
        name: "R-#{SecureRandom.hex(3)}",
        permissions: %w[view_daily_reconciliation view_pos_transactions_verification view_all_employee_reconciliation_summary]
      )
      supervisor = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, cashier_role.id) }
      cashier    = create(:user, business: business, first_name: "Mona", last_name: "Fathy")

      card_pm = PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: card_pm, payment_method_name: "Visa",
                                collected_amount: 500, refund_amount: 0)

      # A self-deposit (day-close) handover is the minimal fixture that makes
      # Finance::EmployeeReconciliationSummarizer produce a non-empty summary row.
      close = TillHandover.create!(
        daily_reconciliation: dr, from_user: cashier, self_deposit: true, accepted_at: Time.current
      )
      TillHandoverAmount.create!(till_handover: close, payment_method: card_pm, payment_method_name: "Visa",
                                 collected_amount: 500, refund_amount: 0, kind: "operational")

      create_pos_transaction!(cashier: "Mona Fathy", payment_method_name: "Visa")

      sign_in supervisor
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.employee_summary_title"))
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.session_totals_title"))
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.col_pos_total"))
      expect(response.body).to include("Mona Fathy")
    end

    it "does not render the removed Electronic Payment Transactions section" do
      sign_in viewer
      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include("Electronic Payment Transactions")
    end

    it "shows the import link for a user who additionally has manage_pos_import" do
      sign_in importer
      get finance_daily_reconciliation_path(dr)
      expect(response.body).to include(new_finance_pos_import_path)
    end

    it "hides the import link for a user with only the view permission" do
      sign_in viewer
      get finance_daily_reconciliation_path(dr)
      expect(response.body).not_to include(new_finance_pos_import_path)
    end
  end

  describe "direct endpoint access" do
    it "blocks a user without the permission from the POS import index" do
      sign_in no_perm
      get finance_pos_imports_path
      expect(response).to redirect_to(root_path)
    end

    it "blocks a user without the permission from starting a new POS import" do
      sign_in no_perm
      get new_finance_pos_import_path
      expect(response).to redirect_to(root_path)
    end

    it "allows a user with manage_pos_import to reach the POS import index" do
      sign_in importer
      get finance_pos_imports_path
      expect(response).to have_http_status(:success)
    end
  end

  describe "permission assignment via the role system" do
    it "grants access once the permission is added to the role" do
      role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: %w[view_daily_reconciliation])
      user = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }

      sign_in user
      get finance_daily_reconciliation_path(dr)
      expect(response.body).not_to include(I18n.t("finance.pos_imports.verification.title"))

      role.update!(permissions: role.permissions + %w[view_pos_transactions_verification])

      get finance_daily_reconciliation_path(dr)
      expect(response.body).to include(I18n.t("finance.pos_imports.verification.title"))
    end

    it "revokes access once the permission is removed from the role" do
      role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                                 permissions: %w[view_daily_reconciliation view_pos_transactions_verification])
      user = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }

      sign_in user
      get finance_daily_reconciliation_path(dr)
      expect(response.body).to include(I18n.t("finance.pos_imports.verification.title"))

      role.update!(permissions: %w[view_daily_reconciliation])

      get finance_daily_reconciliation_path(dr)
      expect(response.body).not_to include(I18n.t("finance.pos_imports.verification.title"))
    end
  end
end
