require_relative "application"

# Validate RAILS_MASTER_KEY before any engine (including Devise) attempts to
# read secret_key_base. Devise's engine initializer runs before config/initializers/
# files, so this is the only place early enough to produce a readable error.
# SECRET_KEY_BASE_DUMMY=1 is set during `assets:precompile` in the Docker build
# stage — no real key is available or needed there, so skip the check.
if ENV.fetch("RAILS_ENV", "development") == "production" &&
   ENV["SECRET_KEY_BASE_DUMMY"].nil?
  _key = ENV.fetch("RAILS_MASTER_KEY", "")

  if _key.empty?
    abort "[WorkPulse] FATAL: RAILS_MASTER_KEY is not set.\n" \
          "Set it in .env or pass it to docker compose."
  end

  unless _key.length == 32 && _key.match?(/\A[0-9a-f]+\z/i)
    abort "[WorkPulse] FATAL: RAILS_MASTER_KEY has invalid format.\n" \
          "  Length : #{_key.length} chars (must be 32)\n" \
          "  Content: #{_key.gsub(/[0-9a-f]/i, '*')}\n" \
          "  Tip    : run  printf 'RAILS_MASTER_KEY=%s\\n' \"$(cat config/master.key)\"\n" \
          "           and check for a trailing % (zsh shell artifact)"
  end
end

Rails.application.initialize!
