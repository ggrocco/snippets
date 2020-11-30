#!/usr/bin/env ruby
# frozen_string_literal: true

# Helper for interact with Kubeclt and Helm.
# Author: https://github.com/ggrocco
# Last Change: 2020-11-27
# TO DEBUG call whit DEBUG=true before the call

require 'base64'
require 'json'
require 'mkmf'
require 'open3'
require 'tempfile'
require 'thor'
require 'yaml'
# require 'pry-byebug'

# Base helper
class BaseHelper
  attr_reader :namespace

  def initialize(namespace)
    @namespace = namespace
  end

  def search_by_name(match: nil, objects: 'pods', namespace: 'default')
    pods = kubectl("get #{objects} -o=name -n #{namespace}").split("\n")

    pods = pods.select { |n| n.match(%r{^pod/#{namespace}}) } if namespace != 'default'
    pods.select { |n| n.match(/#{match}/) }.first
  end

  def chart_name
    @chart_name ||= begin
      Dir.chdir('chart') { Dir.glob('*').select { |f| File.directory? f } }.first
    rescue StandardError
      nil
    end
  end

  def chart_version
    @chart_version ||= YAML.load_file("chart/#{chart_name}/Chart.yaml")['apiVersion']
  end

  def envs
    @envs ||= Dir.glob("chart/#{chart_name}/values*.yaml").each_with_object({}) do |f, hash|
      repository = YAML.load_file(f)['image']['repository']
      _host, chart, environment = repository.split('/')
      hash[environment] = { file: f, chart: chart }
    end
  end

  def default_values_file
    @default_values_file ||= begin
      file = envs.values
                 .map { |v| v[:file] }
                 .first { |v| /values\.yaml$/.match?(v) }

      exit_msg('Default values.yaml file not found!') if file.nil?

      file
    end
  end

  def secret_name
    por_name = search_by_name(namespace: namespace)
    json_path = 'jsonpath={.spec.containers[].env[*].valueFrom.secretKeyRef.name}'
    name = kubectl("get #{por_name} -n #{namespace} -o #{json_path}").split.uniq.first
    exit_msg("Secret not found on '#{namespace}', check if this namespace exist on this cluster") if name.empty?

    name
  end

  def repository
    por_name = search_by_name(namespace: namespace)
    repository = kubectl("get #{por_name} -n #{namespace} -o jsonpath={.spec.containers[].image}")
    exit_msg("Repository not found on '#{namespace}', check if this namespace exist on this cluster") if repository.nil?

    repository
  rescue StandardError
    exit_msg("FAIL on get the repository on '#{namespace}',  check you are at the correct cluster")
  end

  def exit_msg(msg)
    puts msg
    exit(1)
  end

  def helm(arguments, print: false)
    executable = chart_version == 'v1' ? 'helm2' : 'helm'
    cmd        = find_executable0(executable)

    exit_msg("Needs to have #{executable} installed") if cmd.nil?
    run(executable, arguments, print)
  end

  def kubectl(arguments, print: false)
    exit_msg('Needs to have kubectl installed') unless find_executable0('kubectl')
    run('kubectl', arguments, print)
  end

  def aws(arguments, print: false)
    exit_msg('Needs to have AWS Cli installed') unless find_executable0('aws')
    run('aws', arguments, print)
  end

  def run(prog, arguments, print)
    command = "#{prog} #{arguments}"
    puts command if ENV['DEBUG'] == 'true'

    stdout, stderr, status = Open3.capture3(command)
    exit_msg("Fail on execute the #{prog}: #{stderr}") unless status.success?

    stdout = stdout.slice(0..-(1 + "\n".size)) if stdout.end_with?("\n")
    puts stdout if print

    stdout
  rescue StandardError => e
    exit_msg("Fail on execute the #{prog}: #{e.message} \n #{e.backtrace}")
  end
end

# Rollout
class Rollout < BaseHelper
  def restart
    kubectl("rollout restart deploy -n #{namespace}", print: true)
  end
end

class RollbackHelm < BaseHelper
  REGEX_PARSE_SEMVER = /^(\d+)\.(\d+)\.(\d+)(?:-[a-z]+)?(?:\.(\d+))?/i.freeze

  def rollback(version_to_rollback = nil)
    puts 'Rollback helm'

    repository = repository_name

    old_version, new_version = from_to_versions(repository, version_to_rollback)

    puts "Moving the verions #{old_version} to new #{new_version}"
    rename_tags(repository, old_version, new_version)
  end

  private

  def from_to_versions(repository, version_to_rollback = nil)
    versions = versions(repository)

    old_version, current_version = select_last_two_versions(versions)
    base_version = version_to_rollback || old_version

    exit_msg('FATAL!!! Do not exist a version to do the rollback!!!') unless versions.include?(base_version)

    new_version = build_release_candidate(current_version)

    [base_version, new_version]
  end

  def versions(repository)
    images = aws("ecr list-images --repository-name #{repository} --output text --max-items 100")
    images.split("\n").map { |l| l.split("\t").last }.sort
  end

  def select_last_two_versions(versions)
    if versions.last == 'latest'
      versions.slice(-3, 2)
    else
      versions.slice(-2, 2)
    end
  end

  def repository_name
    project, env_version = repository.split('/').slice(-2, 2)
    "#{project}/#{env_version.split(':').first}"
  end

  def build_release_candidate(current_version)
    major, minor, patch, pre_release = REGEX_PARSE_SEMVER.match(current_version).captures.map(&:to_i)

    patch += 1 if pre_release.zero?
    pre_release += 1

    "#{major}.#{minor}.#{patch}-rc.#{pre_release}"
  end

  def rename_tags(repository, current_version, new_version)
    file = Tempfile.new('manifest')

    get_manifest_command = <<~CMD
      ecr batch-get-image --repository-name #{repository} \
                          --image-ids imageTag=#{current_version} \
                          --query 'images[].imageManifest' \
                          --output text > #{file.path}
    CMD
    aws(get_manifest_command)
    aws("ecr put-image --repository-name #{repository} --image-tag #{new_version} --image-manifest file://#{file.path}")

    file.unlink
  end
end

#
# Upgrade the helm helper
class UpgradeHelm < BaseHelper
  attr_reader :version

  def initialize(namespace, version = nil)
    super(namespace)

    @version = version
  end

  # Run the Helm upgrade.
  def upgrade
    puts 'Upgrading helm'
    env, repo_version = extract_env_version(repository)
    @version ||= repo_version
    explicit_ns = " -n #{namespace}" if chart_version == 'v2' # because don't have tiller.

    helm("upgrade #{namespace}#{explicit_ns} ./chart/#{chart_name} -f ./#{env[:file]} --set=image.tag=#{@version}",
         print: true)
  end

  def extract_env_version(repository)
    _, chart, image_version = repository.split('/')
    envrionment, version = image_version.split(':')

    env = envs[envrionment]
    exit_msg('FATAL!!! This chart is not for this repository!!!') if chart != env[:chart]

    [env, version]
  end
end

# Patch secret helper
class PatchSecretHelper < BaseHelper
  attr_reader :key, :value

  def initialize(namespace, key, value)
    super(namespace)
    @key = key
    @value = value
  end

  def patch
    if RUBY_PLATFORM =~ /mswin|mingw32/
      puts 'NOTE: because of some incompatibility needs to be performed manually:'
      puts "kubectl patch secret #{secret_name} -n #{namespace} --patch '#{data_value}'"
    else
      kubectl("patch secret #{secret_name} -n #{namespace} --patch '#{data_value}'", print: true)
    end
  end

  private

  def data_value
    { 'data' => { key.downcase => encoded_value } }.to_json
  end

  def encoded_value
    Base64.encode64(value).delete("\n").strip
  end
end

# Base database helpers
class BaseDatabaseHelper < BaseHelper
  def build_database_uri
    encoded_url = kubectl("get secret #{secret_name} -o yaml -n #{namespace} -o jsonpath={.data.database_url}")
    url = Base64.decode64(encoded_url)

    exit_msg("DATABASE_URL not register on '#{namespace}', check if this secret file exist on this cluster") if url.nil?

    uri = URI.parse(url)
    uri.host = '127.0.0.1'
    uri.port = 3307
    uri
  end

  def open_database_connection(&block)
    puts '-> Open database connection'
    pod = search_by_name(match: 'rds-fwd-socat')
    tunnel = Process.spawn("kubectl -n default port-forward #{pod} 3307:3306")
    sleep 3 # wait the connection start
    block.call
  ensure
    puts '-> Closing database connection'
    Process.kill(9, tunnel)
  end
end

# Run the rake migration helper
class RakeMigrate < BaseDatabaseHelper
  # Open a connection with cluster an run the rake db:migrate
  def migrate
    puts 'Starting migration...'
    open_database_connection do
      database_uri = build_database_uri
      puts '-> Running the rake db:migrate'
      puts `rake db:migrate DATABASE_URL=#{database_uri}`
    end
  end
end

# Database dump helper
class DatabaseDump < BaseDatabaseHelper
  attr_reader :database_name

  def initialize(namespace, database_name = nil)
    super(namespace)
    @database_name = database_name
  end

  # Open a connection with cluster an run the mysqldump
  def dump
    puts 'Starting migration...'
    open_database_connection do
      database_uri = build_database_uri
      @database_name ||= database_uri.path.split('/')[1]

      puts '-> Running the mysqldump'
      command = "mysqldump -h #{database_uri.host} -P #{database_uri.port} -u #{database_uri.user} " \
                "--password=#{database_uri.password} #{@database_name} | #{compress_cmd}"
      puts `#{command}`
    end
  end

  private

  def compress_cmd
    output_file = "#{@database_name}-#{Time.now.strftime('%Y%m%d-%H%M%S')}.sql"
    compress_command(output_file)
  end

  def compress_command(output_file)
    if program?('7z') || program?('7z.exe')
      "7z a -si #{output_file}.7z"
    else
      "gzip > #{output_file}.gz"
    end
  end

  def program?(program)
    ENV['PATH'].split(File::PATH_SEPARATOR).any? do |directory|
      File.executable?(File.join(directory, program.to_s))
    end
  end
end

# Valid if the secrets are registered correctly.
class ValidSecret < BaseHelper
  def check!
    missing_secrets = chart_secrets - deployed_secrets
    if missing_secrets.empty?
      puts 'Secrets are sync!'
    else
      exit_msg("The folling secrets are missing at the cluster: '#{missing_secrets.join(', ')}'")
    end
  end

  private

  def deployed_secrets
    file = kubectl("get secret #{secret_name} -n #{namespace} -o yaml")

    YAML.safe_load(file)['data'].keys.compact
  end

  def chart_secrets
    YAML.load_file(default_values_file)['secrets']
  end
end

# Helper methods
class ValidBase < BaseHelper
  def check!
    exit_msg("This cluster don't have the namespace #{namespace}") unless exist_namespace?
    exit_msg('This directory does not have a chart folder') if chart_name.nil?
    exit_msg('This directory does not have environments defined') if envs.empty?
  end

  private

  def exist_namespace?
    !search_by_name(objects: 'namespace', match: "^namespace/#{namespace}").nil?
  end
end

# Cli control.
class KCli < Thor
  def self.exit_on_failure?
    true
  end

  class_option :namespace, type: :string, aliases: '-n', required: true, desc: 'Namespace on the clusters'

  desc 'upgrade', 'Upgrade the helm'
  method_option :version, type: :string, aliases: '-v', desc: 'Change the version, default keep the same'
  method_option :recreate_pods, type: :boolean, aliases: '-r', desc: 'Recreate the pods'
  def upgrade
    valid_environment
    valid_secret
    UpgradeHelm.new(options[:namespace], options[:version]).upgrade
    restart_pods if options[:recreate_pods]
  end

  desc 'restart', 'Rollout restart pods'
  def restart_pods
    Rollout.new(options[:namespace]).restart
  end

  desc 'rollback', 'Rollback the helm'
  method_option :version, type: :string, aliases: '-v', desc: 'Rollback to this version'
  def rollback
    valid_environment
    RollbackHelm.new(options[:namespace]).rollback(options[:version])
  end

  desc 'valid_environment', 'Valid if the chart and folder is correct setup'
  def valid_environment
    ValidBase.new(options[:namespace]).check!
  end

  desc 'valid_secret', 'Valid if the secrets are registered correctly'
  def valid_secret
    ValidSecret.new(options[:namespace]).check!
  end

  desc 'migrate', 'Run the migration on the database'
  def migrate
    valid_environment
    RakeMigrate.new(options[:namespace]).migrate
  end

  desc 'patch_secret', 'Update a secret key'
  method_option :key, type: :string, aliases: '-k', required: true, desc: 'Key to be upgrade'
  method_option :value, type: :string, aliases: '-v', required: true, desc: 'Value to be defined'
  def patch_secret
    valid_environment
    PatchSecretHelper.new(options[:namespace], options[:key], options[:value]).patch
  end

  desc 'dump', 'Run the mysqldump on the database'
  method_option :database, type: :string, aliases: '-d', desc: 'For change from default detabase'
  def dump
    valid_environment
    DatabaseDump.new(options[:namespace], options[:database]).dump
  end
end
KCli.start(ARGV)
