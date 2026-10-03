require "rails_helper"

RSpec.describe Api::V1::BaseSerializer do
  let(:serializer_class) do
    Class.new(described_class) do
      attributes :id, :first_name
      attribute(:display_name) { "#{record.first_name} #{record.last_name}".strip }
      attribute(:viewer_id)    { viewer&.id }
    end
  end

  let(:user) { build_stubbed(:user, first_name: "Ali", last_name: "Zed") }

  it "serializes only the declared attributes, in order" do
    expect(serializer_class.one(user, viewer: user)).to eq(
      id: user.id, first_name: "Ali", display_name: "Ali Zed", viewer_id: user.id
    )
  end

  it "serializes collections and nil" do
    expect(serializer_class.many([ user, user ]).size).to eq(2)
    expect(serializer_class.one(nil)).to be_nil
  end

  it "refuses credential and secret attributes at definition time" do
    %i[encrypted_password reset_password_token token refresh_token].each do |name|
      expect { Class.new(described_class) { attributes name } }.to raise_error(ArgumentError, /sensitive/)
    end
  end

  it "does not leak attributes between serializer classes" do
    other = Class.new(described_class) { attributes :email }
    expect(serializer_class._fields.map(&:first)).not_to include(:email)
    expect(other._fields.map(&:first)).to eq([ :email ])
  end
end
