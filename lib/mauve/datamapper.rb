#
#
# Small loader to put all our Datamapper requirements together
#
#
require 'dm-core'
require 'dm-migrations'
require 'dm-aggregates'
%w(dm-sqlite-adapter-with-mutex dm-postgres-adapter).each do |req|
  require req
end
require 'dm-transactions'
require 'dm-types'
require 'dm-validations-with-empty-errors-hack'

# DataMapper::Model.raise_on_save_failure = true

