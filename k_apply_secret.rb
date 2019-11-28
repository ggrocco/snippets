#!/usr/bin/env ruby
# frozen_string_literal: true

# This script will encrypt and apply the secret file,
# will need to have the namespace on.
# Author: https://github.com/ggrocco
# Last Change: 2018-09-11

require 'base64'
require 'yaml'
require 'tempfile'

INPUT = ARGV[0]
VALID_EXT = '.yaml'

unless INPUT && File.exist?(INPUT) && File.extname(INPUT) == VALID_EXT
  puts 'Need to have a base secrets file for be encoded'
  puts "Ex: $ #{__FILE__} BASE_SECRET_FILE.yaml"
  exit 1
end

file = File.basename(INPUT)
input_file = YAML.load_file(INPUT)
data = input_file['data']

unless data.is_a?(Hash)
  puts 'This file is not a base secret file'
  exit 1
end

puts "Processing the file #{file}"
output = {}
data.each do |key, value|
  puts "Encoding secret: #{key.downcase}"
  output[key.downcase] = Base64.encode64(value.to_s).delete("\n").strip
end

input_file['data'] = output

file = Tempfile.new(file)
file.write(input_file.to_yaml)
file.close

system("kubectl apply -f #{file.path}")
file.unlink
puts 'Done.'
