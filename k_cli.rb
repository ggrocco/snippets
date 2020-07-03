#!/usr/bin/env ruby
# frozen_string_literal: true

# Helper for interact with Kubeclt and Helm.
# Author: https://github.com/ggrocco
# Last Change: 2020-07-02

require 'base64'
require 'mkmf'
require 'open3'
require 'thor'
require 'yaml'
# require 'pry-byebug'

# Base helper
class BaseHelper
  def search_by_name(match: nil, objects: 'pods', namespace: 'default')
    pods = kubectl("get #{objects} -o=name -n #{namespace}").split("\n")
    pods.select { |n| n.match(/#{match}/) }.first
  end

  def chart_name
    @chart_name ||= begin
                      Dir.chdir('chart') { Dir.glob('*').select { |f| File.directory? f } }.first
                    rescue StandardError
                      nil
                    end
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

  def secret_name(namespace: 'default')
    por_name = search_by_name(namespace: namespace)
    json_path = 'jsonpath={.spec.containers[].env[1].valueFrom.secretKeyRef.name}'
    secret_name = kubectl("get #{por_name} -n #{namespace} -o #{json_path}")
    exit_msg("Secret not found on '#{namespace}', check if this namespace exist on this cluster") if secret_name.empty?

    secret_name
  end

  def exit_msg(msg)
    puts msg
    exit(1)
  end

  def helm(arguments, print: false)
    prog = if find_executable0('helm2')
             'helm2'
           elsif find_executable0('helm')
             'helm'
           end

    exit_msg('Needs to have helm version 2 installed') if prog.nil?
    run(prog, arguments, print)
  end

  def kubectl(arguments, print: false)
    exit_msg('Needs to have kubectl installed') unless find_executable0('kubectl')
    run('kubectl', arguments, print)
  end

  def run(prog, arguments, print)
    stdout, stderr, status = Open3.capture3("#{prog} #{arguments}")
    exit_msg("Fail on execute the #{prog}: #{stderr}") unless status.success?

    stdout = stdout.slice(0..-(1 + "\n".size)) if stdout.end_with?("\n")
    puts stdout if print

    stdout
  rescue StandardError => e
    exit_msg("Fail on execute the #{prog}: #{e.message} \n #{e.backtrace}")
  end
end

# Upgrade the helm helper
class UpgradeHelm < BaseHelper
  attr_reader :namespace, :recreate_pods, :version

  def initialize(namespace, recreate_pods, version = nil)
    @namespace = namespace
    @recreate_pods = recreate_pods
    @version = version
  end

  # Run the Helm upgrade.
  def upgrade
    puts 'Upgrading helm'
    env, repo_version = repository
    @version ||= repo_version

    helm("upgrade #{@namespace} ./chart/#{chart_name} -f ./#{env[:file]} --set=image.tag=#{@version}", print: true)
    kubectl("rollout restart deploy -n #{@namespace}", print: true) if @recreate_pods
  end

  private

  def repository
    por_name = search_by_name(namespace: @namespace)
    repository = kubectl("get #{por_name} -n #{@namespace} -o jsonpath={.spec.containers[].image}")
    if repository.nil?
      exit_msg("Repository not found on '#{@namespace}', check if this namespace exist on this cluster")
    end

    extract_env_version(repository)
  rescue StandardError
    exit_msg("FAIL on get the repository on '#{@namespace}',  check you are at the correct cluster")
  end

  def extract_env_version(repository)
    _, chart, image_version = repository.split('/')
    envrionment, version = image_version.split(':')

    env = envs[envrionment]
    exit_msg('FATAL!!! This chart is not for this repository!!!') if chart != env[:chart]

    [env, version]
  end
end

# Base database helpers
class BaseDatabaseHelper < BaseHelper
  attr_reader :namespace

  def initialize(namespace)
    @namespace = namespace
  end

  def build_database_uri
    secret = secret_name(namespace: @namespace)
    encoded_url = kubectl("get secret #{secret} -o yaml -n #{@namespace} -o jsonpath={.data.database_url}")
    url = Base64.decode64(encoded_url)
    if url.nil?
      exit_msg("DATABASE_URL not register on '#{@namespace}', check if this secret file exist on this cluster")
    end

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
  def initialize(namespace)
    @namespace = namespace
  end

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
    secret = secret_name(namespace: @namespace)
    file = kubectl("get secret #{secret} -n #{@namespace} -o yaml")

    YAML.safe_load(file)['data'].keys.compact
  end

  def chart_secrets
    YAML.load_file(default_values_file)['secrets']
  end
end

# Helper methods
class ValidBase < BaseHelper
  def initialize(namespace)
    @namespace = namespace
  end

  def check!
    exit_msg("This cluster don't have the namespace #{@namespace}") unless exist_namespace?
    exit_msg('This directory does not have a chart folder') if chart_name.nil?
    exit_msg('This directory does not have environments defined') if envs.empty?
  end

  private

  def exist_namespace?
    !search_by_name(objects: 'namespace', match: "^namespace/#{@namespace}").nil?
  end
end

# Cli control.
class KCli < Thor
  class_option :namespace, type: :string, aliases: '-n', required: true, desc: 'Namespace on the clusters'

  desc 'upgrade', 'Upgrade the helm'
  method_option :version, type: :string, aliases: '-v', desc: 'Change the version, default keep the same'
  method_option :recreate_pods, type: :boolean, aliases: '-r', desc: 'Recreate the pods.'
  def upgrade
    namespace = options[:namespace]
    ValidBase.new(namespace).check!
    ValidSecret.new(namespace).check!
    UpgradeHelm.new(namespace, options[:recreate_pods], options[:version]).upgrade
  end

  desc 'valid_secret', 'Valid if the secrets are registered correctly'
  def valid_secret
    ValidSecret.new(options[:namespace]).check!
  end

  desc 'migrate', 'Run the migration on the database'
  def migrate
    ValidBase.new(options[:namespace]).check!
    RakeMigrate.new(options[:namespace]).migrate
  end

  desc 'dump', 'Run the mysqldump on the database'
  method_option :database, type: :string, aliases: '-d', desc: 'For change from default detabase'
  def dump
    ValidBase.new(options[:namespace]).check!
    DatabaseDump.new(options[:namespace], options[:database]).dump
  end
end
KCli.start(ARGV)
