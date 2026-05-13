# Custom permit matcher compatible with describe "action?" block structure.
# Usage: expect(PolicyClass).to permit(user, record)
# The action is inferred by scanning ancestor describe descriptions for "word?".
RSpec::Matchers.define :permit do |user, record|
  match do |policy_class|
    action = infer_action
    raise "Could not infer policy action from describe context" unless action
    policy_class.new(user, record).public_send(action)
  end

  failure_message { |klass| "expected #{klass} to permit #{user} on #{record}" }
  failure_message_when_negated { |klass| "expected #{klass} not to permit #{user} on #{record}" }

  def infer_action
    meta = RSpec.current_example.metadata[:example_group]
    while meta
      action = meta[:description].to_s.scan(/\b\w+\?/).first
      return action.to_sym if action
      meta = meta[:parent_example_group]
    end
    nil
  end
end
