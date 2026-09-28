# ApplicationController#set_locale assigns I18n.locale per request, which
# otherwise leaks into later examples on the same thread (e.g. an Arabic request
# spec making a later spec's English message assertion fail). Reset it.
RSpec.configure do |config|
  config.after { I18n.locale = I18n.default_locale }
end
