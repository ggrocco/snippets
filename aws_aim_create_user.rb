#!/usr/bin/env ruby

require 'securerandom'
require 'json'

email = ARGV[0]
groups = ARGV[1]
add_access_keys = ARGV[2] == 'true'
temp_password = SecureRandom.base64(16)

unless email && groups
  puts 'To create user please follow the example command'
  puts "Ex: $ #{__FILE__} email groups [add access key: true/false]"
  exit 1
end


def exec(command, field = nil)
  output=`#{command}`
  return JSON.parse(output) if $?.success? && !output.strip.empty?
  {}
end

@output = {}
user = exec("aws iam create-user --user-name #{email}")
@output[:email] = user.dig('User', "UserName")

exec("aws iam create-login-profile --user-name #{email} --password-reset-required --password #{temp_password}")
@output[:temp_password] = temp_password

groups.split(',').each do |group|
  exec("aws iam add-user-to-group --user-name #{email} --group-name #{group}")
end

if add_access_keys
  access_key = exec("aws iam create-access-key --user-name #{email}")
  @output[:access_key_id] = access_key.dig('AccessKey', "AccessKeyId")
  @output[:secret_access_key] = access_key.dig('AccessKey', "SecretAccessKey")
end

File.write("#{email}.json", @output.to_json)
