require "rails_helper"

RSpec.describe "Daily Reconciliation — Open Deposit Verification link uses the deposit date", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:actor) { user_with("view_daily_reconciliation", "view_deposit_verification") }
  let(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "deposited",
      opened_at: Time.zone.local(2026, 7, 16, 10, 0, 0),
      closed_at: Time.zone.local(2026, 7, 16, 23, 0, 0),
      business_date: Date.new(2026, 7, 16)
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }

  def deposit(deposited_at:, amount: 100, voided: false)
    d = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                            amount: amount, deposited_at: deposited_at)
    d.update!(voided_at: deposited_at + 1.hour, voided_by: actor, void_reason: "test") if voided
    d
  end

  def verification_link_href(body)
    Nokogiri::HTML(body).at_css("a[href*='deposit_verifications']")&.[]("href")
  end

  before { sign_in actor }

  it "falls back to the DR's business date when there are no deposits yet" do
    get finance_daily_reconciliation_path(dr)

    href = verification_link_href(response.body)
    expect(href).to include("from=2026-07-16")
    expect(href).to include("to=2026-07-16")
  end

  it "uses the single deposit's own date, even when it differs from the DR's business date" do
    deposit(deposited_at: Time.zone.local(2026, 7, 17, 0, 47, 0))

    get finance_daily_reconciliation_path(dr)

    href = verification_link_href(response.body)
    expect(href).to include("from=2026-07-17")
    expect(href).to include("to=2026-07-17")
    expect(href).not_to include("2026-07-16")
  end

  it "uses that single day when multiple deposits fall on the same day" do
    deposit(deposited_at: Time.zone.local(2026, 7, 17, 1, 0, 0), amount: 50)
    deposit(deposited_at: Time.zone.local(2026, 7, 17, 14, 0, 0), amount: 50)

    get finance_daily_reconciliation_path(dr)

    href = verification_link_href(response.body)
    expect(href).to include("from=2026-07-17")
    expect(href).to include("to=2026-07-17")
  end

  it "spans from the earliest to the latest deposit date when deposits cross multiple days" do
    deposit(deposited_at: Time.zone.local(2026, 7, 17, 1, 0, 0), amount: 50)
    deposit(deposited_at: Time.zone.local(2026, 7, 19, 9, 0, 0), amount: 50)

    get finance_daily_reconciliation_path(dr)

    href = verification_link_href(response.body)
    expect(href).to include("from=2026-07-17")
    expect(href).to include("to=2026-07-19")
  end

  it "ignores voided deposits and falls back to the business date when only voided deposits exist" do
    deposit(deposited_at: Time.zone.local(2026, 7, 17, 0, 47, 0), voided: true)

    get finance_daily_reconciliation_path(dr)

    href = verification_link_href(response.body)
    expect(href).to include("from=2026-07-16")
    expect(href).to include("to=2026-07-16")
  end

  it "ignores a voided deposit's date even when an active deposit also exists on a different day" do
    deposit(deposited_at: Time.zone.local(2026, 7, 20, 5, 0, 0), voided: true)
    deposit(deposited_at: Time.zone.local(2026, 7, 17, 0, 47, 0))

    get finance_daily_reconciliation_path(dr)

    href = verification_link_href(response.body)
    expect(href).to include("from=2026-07-17")
    expect(href).to include("to=2026-07-17")
    expect(href).not_to include("2026-07-20")
  end

  it "preserves the branch filter" do
    deposit(deposited_at: Time.zone.local(2026, 7, 17, 0, 47, 0))

    get finance_daily_reconciliation_path(dr)

    href = verification_link_href(response.body)
    expect(href).to include("branch_id=#{branch.id}")
  end

  it "does not render the link at all without view_deposit_verification permission" do
    viewer = user_with("view_daily_reconciliation")
    sign_out actor
    sign_in viewer

    get finance_daily_reconciliation_path(dr)

    expect(verification_link_href(response.body)).to be_nil
  end
end
