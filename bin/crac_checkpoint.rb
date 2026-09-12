# frozen_string_literal: true

# CRaC pre-boot for CheckpointMain (--checkpoint → -XX:CRaCCheckpointTo).
# Load Bundler + the Sinatra app into the runtime that will be snapshotted.
# Must not open a listen socket, a JDBC pool, or register with the CMS —
# those are restored-identity and are acquired after --restore in config.ru.
require "bundler/setup"
require_relative "../app"

if CatalogCounters.connect_count.positive?
  abort "crac checkpoint opened a DB pool (connect_count=#{CatalogCounters.connect_count})"
end

Sinatra::Application
LANGUAGE
API_VERSION
ENDPOINTS
