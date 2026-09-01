# frozen_string_literal: true

port = Integer(ENV.fetch("PORT", "4003"))
bind "tcp://[::]:#{port}"
