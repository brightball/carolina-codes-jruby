# frozen_string_literal: true

workers 0
n = Integer(ENV.fetch("PUMA_THREADS", "3")) # 2*cores+1; Fly is 1 shared CPU
threads n, n
environment ENV.fetch("RACK_ENV", "development")

port = Integer(ENV.fetch("PORT", "4003"))
bind "tcp://[::]:#{port}"
