require "rails_helper"

# Regression coverage for the Role Permissions page's localization: every
# permission group and permission key registered in PermissionRole must have
# a real translation in both locales — not a fallback, not "translation
# missing". This is what actually broke for the Laundry groups/permissions:
# config.i18n.fallbacks = true means a missing Arabic key silently renders
# the English value instead of surfacing as an error, so a plain "does ar.yml
# have this key somewhere" check isn't enough — we need to assert the
# resolved value differs between locales when the two languages'
# translations are supposed to differ, and that neither locale falls through
# to Rails' "translation missing: ..." string.
RSpec.describe "PermissionRole registry translations", type: :model do
  let(:groups) { PermissionRole::PERMISSION_GROUPS.keys.map(&:to_s) }
  let(:permissions) { PermissionRole::ALL_PERMISSIONS }

  def translation_missing?(value)
    value.is_a?(String) && value.start_with?("Translation missing", "translation missing")
  end

  describe "group labels" do
    it "has a real English translation for every registered group" do
      I18n.with_locale(:en) do
        groups.each do |group|
          value = I18n.t("admin.permission_roles.groups.#{group}")
          expect(translation_missing?(value)).to be(false), "admin.permission_roles.groups.#{group} is missing in en"
        end
      end
    end

    it "has a real Arabic translation for every registered group" do
      I18n.with_locale(:ar) do
        groups.each do |group|
          value = I18n.t("admin.permission_roles.groups.#{group}")
          expect(translation_missing?(value)).to be(false), "admin.permission_roles.groups.#{group} is missing in ar"
        end
      end
    end

    it "never falls back to the English label for Arabic (each group has its own distinct Arabic string)" do
      groups.each do |group|
        en_value = I18n.t("admin.permission_roles.groups.#{group}", locale: :en)
        ar_value = I18n.t("admin.permission_roles.groups.#{group}", locale: :ar)
        expect(ar_value).not_to eq(en_value), "admin.permission_roles.groups.#{group} resolves identically in ar and en — likely falling back"
      end
    end
  end

  describe "permission labels" do
    it "has a real English translation for every registered permission" do
      I18n.with_locale(:en) do
        permissions.each do |perm|
          value = I18n.t("admin.permission_roles.permissions.#{perm}")
          expect(translation_missing?(value)).to be(false), "admin.permission_roles.permissions.#{perm} is missing in en"
        end
      end
    end

    it "has a real Arabic translation for every registered permission" do
      I18n.with_locale(:ar) do
        permissions.each do |perm|
          value = I18n.t("admin.permission_roles.permissions.#{perm}")
          expect(translation_missing?(value)).to be(false), "admin.permission_roles.permissions.#{perm} is missing in ar"
        end
      end
    end

    it "never falls back to the English label for Arabic (each permission has its own distinct Arabic string)" do
      permissions.each do |perm|
        en_value = I18n.t("admin.permission_roles.permissions.#{perm}", locale: :en)
        ar_value = I18n.t("admin.permission_roles.permissions.#{perm}", locale: :ar)
        expect(ar_value).not_to eq(en_value), "admin.permission_roles.permissions.#{perm} resolves identically in ar and en — likely falling back"
      end
    end
  end

  describe "dependency labels" do
    it "resolves every dependency through the same permission translation key (no separate dependency-label storage)" do
      PermissionRole::PERMISSION_DEPENDENCIES.each_value do |deps|
        deps.each do |dep|
          expect(permissions).to include(dep) # every dependency is itself a registered permission
          [ :en, :ar ].each do |locale|
            value = I18n.t("admin.permission_roles.permissions.#{dep}", locale: locale)
            expect(translation_missing?(value)).to be(false), "dependency label for #{dep} is missing in #{locale}"
          end
        end
      end
    end
  end

  describe "shared form labels" do
    it "translates 'Select all' (select_group) and 'Requires' distinctly per locale" do
      expect(I18n.t("admin.permission_roles.form.select_group", locale: :en)).to eq("All")
      expect(I18n.t("admin.permission_roles.form.select_group", locale: :ar)).to eq("الكل")
      expect(I18n.t("admin.permission_roles.form.requires", locale: :en)).to eq("Requires:")
      expect(I18n.t("admin.permission_roles.form.requires", locale: :ar)).to eq("يتطلب:")
    end
  end
end
