require "rails_helper"

RSpec.describe Finance::Dashboard::ActivityPresenter, type: :model do
  # Presenter never dereferences `auditable`/`actor`/`business` — only reads
  # auditable_type/action/metadata/changes_json — so an unsaved AuditLog with
  # just those fields is enough, no need to build full domain records.
  def log(auditable_type:, action:, metadata: {}, changes_json: {})
    AuditLog.new(auditable_type: auditable_type, auditable_id: 1, action: action,
                metadata: metadata, changes_json: changes_json)
  end

  around do |example|
    original = I18n.locale
    example.run
    I18n.locale = original
  end

  let(:currency_formatter) { ->(amount) { "#{amount} EGP" } }

  describe "TillDeposit" do
    it "translates create into a human sentence, never the class/action name" do
      I18n.locale = :en
      presenter = described_class.new(log(auditable_type: "TillDeposit", action: "create"), currency_formatter: currency_formatter)

      expect(presenter.label).to eq("New deposit recorded")
      expect(presenter.label).not_to include("TillDeposit")
      expect(presenter.label).not_to include("create")
    end

    it "includes the amount when metadata carries one" do
      I18n.locale = :en
      presenter = described_class.new(
        log(auditable_type: "TillDeposit", action: "create", metadata: { "amount" => "5000.0" }),
        currency_formatter: currency_formatter
      )

      expect(presenter.label).to eq("New deposit recorded — 5000.0 EGP")
    end

    it "translates settle-equivalent void with amount" do
      I18n.locale = :en
      presenter = described_class.new(
        log(auditable_type: "TillDeposit", action: "void", metadata: { "amount" => 1200 }),
        currency_formatter: currency_formatter
      )

      expect(presenter.label).to eq("Deposit voided — 1200.0 EGP")
    end
  end

  describe "RemainingDepositBalance" do
    it "translates create" do
      I18n.locale = :en
      presenter = described_class.new(log(auditable_type: "RemainingDepositBalance", action: "create"), currency_formatter: currency_formatter)
      expect(presenter.label).to eq("Remaining deposit balance recorded")
    end

    it "translates settle with amount, distinct wording from create" do
      I18n.locale = :en
      presenter = described_class.new(
        log(auditable_type: "RemainingDepositBalance", action: "settle", metadata: { "amount" => 200 }),
        currency_formatter: currency_formatter
      )

      expect(presenter.label).to eq("Remaining deposit balance settled — 200.0 EGP")
    end

    it "translates write_off without exposing the model name" do
      presenter = described_class.new(log(auditable_type: "RemainingDepositBalance", action: "write_off"), currency_formatter: currency_formatter)
      expect(presenter.label).not_to include("RemainingDepositBalance")
    end

    it "translates reassign without an amount (metadata has no amount for this action)" do
      I18n.locale = :en
      presenter = described_class.new(
        log(auditable_type: "RemainingDepositBalance", action: "reassign", metadata: { "from_user_id" => 1, "to_user_id" => 2 }),
        currency_formatter: currency_formatter
      )

      expect(presenter.label).to eq("Remaining deposit balance reassigned to another employee")
    end
  end

  describe "CustodyTransaction" do
    it "reads the amount from changes_json (not metadata) since that's where it's actually logged" do
      I18n.locale = :en
      presenter = described_class.new(
        log(auditable_type: "CustodyTransaction", action: "balance_top_up", changes_json: { "amount" => [ nil, "300.0" ] }),
        currency_formatter: currency_formatter
      )

      expect(presenter.label).to eq("Custody balance topped up — 300.0 EGP")
    end

    it "does not show an amount for custody_void (not an amount-carrying action)" do
      I18n.locale = :en
      presenter = described_class.new(
        log(auditable_type: "CustodyTransaction", action: "custody_void", changes_json: { "amount" => [ nil, "300.0" ] }),
        currency_formatter: currency_formatter
      )

      expect(presenter.label).to eq("Custody transaction voided")
    end
  end

  describe "Expense" do
    it "translates settle_from_custody" do
      I18n.locale = :en
      presenter = described_class.new(log(auditable_type: "Expense", action: "settle_from_custody"), currency_formatter: currency_formatter)
      expect(presenter.label).to eq("Expense settled from employee custody balance")
    end
  end

  describe "unknown/unmapped activity" do
    it "falls back to a safe generic sentence and never renders the raw class/action name" do
      presenter = described_class.new(log(auditable_type: "SomeFutureModel", action: "did_a_thing"), currency_formatter: currency_formatter)

      expect(presenter.label).not_to include("SomeFutureModel")
      expect(presenter.label).not_to include("did_a_thing")
    end

    it "falls back safely for a known model with an action that was never mapped" do
      presenter = described_class.new(log(auditable_type: "TillDeposit", action: "not_a_real_action"), currency_formatter: currency_formatter)
      expect(presenter.label).not_to include("TillDeposit")
      expect(presenter.label).not_to include("not_a_real_action")
    end

    it "logs a warning for developers when an activity is unmapped" do
      expect(Rails.logger).to receive(:warn).with(a_string_matching(/Unmapped audit activity: SomeFutureModel#did_a_thing/))
      described_class.new(log(auditable_type: "SomeFutureModel", action: "did_a_thing"), currency_formatter: currency_formatter).label
    end
  end

  describe "locales" do
    it "renders Arabic when I18n.locale is :ar" do
      I18n.locale = :ar
      presenter = described_class.new(log(auditable_type: "TillDeposit", action: "create"), currency_formatter: currency_formatter)
      expect(presenter.label).to eq("تم تسجيل إيداع جديد")
    end

    it "renders English when I18n.locale is :en" do
      I18n.locale = :en
      presenter = described_class.new(log(auditable_type: "TillDeposit", action: "create"), currency_formatter: currency_formatter)
      expect(presenter.label).to eq("New deposit recorded")
    end
  end

  describe "currency_formatter injection" do
    it "delegates all currency formatting to the injected formatter (no hardcoded currency logic)" do
      I18n.locale = :en
      formatter = ->(amount) { "€#{amount}" }
      presenter = described_class.new(
        log(auditable_type: "TillDeposit", action: "create", metadata: { "amount" => 10 }),
        currency_formatter: formatter
      )

      expect(presenter.label).to eq("New deposit recorded — €10.0")
    end
  end
end
