#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'iniparse'

unless defined?(IniParse)
  puts "Please install gem `iniparse`"
  exit(1)
end

SESSION_DURATION = 129_600 # 36 hours
AWS_CRERENTIALS_FILE = "#{Dir.home}/.aws/credentials"
AWS_MFA_PROFILE = 'with-mfa'

aws_token = ARGV[0]
aws_profile = ARGV[1] || 'default'

unless File.exist?(AWS_CRERENTIALS_FILE)
  puts 'Configure your AWS credentials first.'
  exit
end

if aws_token.nil? || aws_token.empty?
  puts 'Usage: `./aws-mfa-token <MFA-TOKEN> [<PROFILE>]'
  puts '  - MFA-TOKEN needs to be enable at the AWS Account'
  exit
end

def json_path(content, *path)
  json = JSON.parse(content)
  json.dig(*path)
end

mfa_device_code = json_path(`aws iam list-mfa-devices --profile #{aws_profile}`, 'MFADevices', 0, 'SerialNumber')
get_session = "aws sts get-session-token --profile #{aws_profile} --duration-seconds #{SESSION_DURATION} " \
              "--serial-number #{mfa_device_code} --token-code #{aws_token}"
new_session = `#{get_session}`

aws_access_key_id = json_path(new_session, 'Credentials', 'AccessKeyId')
aws_secret_access_key = json_path(new_session, 'Credentials', 'SecretAccessKey')
aws_session_token = json_path(new_session, 'Credentials', 'SessionToken')

credentials = IniParse.parse(File.read(AWS_CRERENTIALS_FILE))
credentials.section(AWS_MFA_PROFILE)
credentials[AWS_MFA_PROFILE]['aws_access_key_id'] = aws_access_key_id
credentials[AWS_MFA_PROFILE]['aws_secret_access_key'] = aws_secret_access_key
credentials[AWS_MFA_PROFILE]['aws_session_token'] = aws_session_token
credentials.save(AWS_CRERENTIALS_FILE)

puts "Session profile 'with-mfa' will expire on #{json_path(new_session, 'Credentials', 'Expiration')}"
