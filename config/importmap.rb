# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin "leaflet", to: "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet-src.esm.js"
pin "flatpickr", to: "https://cdn.jsdelivr.net/npm/flatpickr@4.6.13/dist/esm/index.js"
pin "flatpickr/ar", to: "https://cdn.jsdelivr.net/npm/flatpickr@4.6.13/dist/esm/l10n/ar.js"
pin_all_from "app/javascript/controllers", under: "controllers"
