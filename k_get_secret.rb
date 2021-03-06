#!/usr/bin/env ruby
# frozen_string_literal: true

# This script will decrypt a secret file data and build
# other based on the internal template.
# Author: https://github.com/ggrocco
# Last Change: 2020-11-30

require 'base64'
require 'yaml'
# require 'pry-byebug'

SECRET_NAME = ARGV[0]
NAMESPACE = ARGV[1] || 'default'

unless SECRET_NAME && NAMESPACE
  puts 'To download needs to have the secret name and namespace'
  puts "Ex: $ #{__FILE__} SECRET_NAME NAMESPACE"
  exit 1
end

file = `kubectl get secret #{SECRET_NAME} -n #{NAMESPACE} -o yaml`
if file.empty?
  puts 'Fail on retrieve the secret'
  exit 1
end

YAML_TEMPLATE = <<-YAML
  apiVersion: v1
  kind: Secret
  metadata:
    name: #{SECRET_NAME}
    namespace: #{NAMESPACE}
  type: Opaque
  data:
YAML

output_file = YAML.safe_load(YAML_TEMPLATE)
output_file['data'] = {}

YAML.safe_load(file)['data'].each do |key, value|
  output_file['data'][key] = value ? Base64.decode64(value) : nil
end

puts output_file.to_yaml
