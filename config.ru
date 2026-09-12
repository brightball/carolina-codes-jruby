# frozen_string_literal: true

require_relative "app"
acquire_after_restore!
run Sinatra::Application
