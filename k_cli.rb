#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thor'
require 'yaml'
require 'base64'
# require 'pry-byebug'

# Helper methods
module Helper
  # Run the Helm upgrade.
  def helm_upgrade(namespace, recreate_pods, version)
    puts 'Upgrading helm'
    env, repo_version = repository(namespace)

    extra = recreate_pods ? ' --recreate-pods' : ''
    version ||= repo_version

    puts `helm upgrade #{namespace} ./chart/#{chart_name} -f ./#{env[:file]} --set=image.tag=#{version}#{extra}`
  end

  # Open a connection with cluster an run the rake db:migrate
  def rake_migrate(namespace)
    puts 'Starting migration...'
    open_database_connection do
      database_uri = build_database_uri(namespace)
      puts '-> Running the rake db:migrate'
      puts `DATABASE_URL=#{database_uri} rake db:migrate`
    end
  end

  # Open a connection with cluster an run the mysqldump
  def mysqldump(namespace, database_name = nil)
    puts 'Starting migration...'
    open_database_connection do
      database_uri = build_database_uri(namespace)
      database_name ||= database_uri.path.split('/')[1]
      puts '-> Running the mysqldump'
      puts `mysqldump -h #{database_uri.host} -P #{database_uri.port} -u #{database_uri.user} --password=#{database_uri.password} #{database_name} | gzip > #{database_name}-#{Time.now.strftime('%Y%m%d-%H%M%S')}.sql.gz`
    end
  end

  def check!(namespace)
    unless exist_namespace?(namespace)
      exit_msg("This cluster don't have the namespace #{namespace}")
    end
    exit_msg('This directory does not have a chart folder') if chart_name.nil?
    exit_msg('This directory does not have environments defined') if envs.empty?
  end

  private

  def build_database_uri(namespace)
    secret_name = `kubectl get #{search_by_name(namespace: namespace)} -n #{namespace} -o jsonpath='{.spec.containers[].env[].valueFrom.secretKeyRef.name}'`
    if secret_name.nil?
      exit_msg("Secret not found on '#{namespace}', check if this namespace exist on this cluster")
    end

    encoded_url = `kubectl get secret #{secret_name} -o yaml -n #{namespace} -o jsonpath='{.data.database_url}'`
    url = Base64.decode64(encoded_url)
    if url.nil?
      exit_msg("DATABASE_URL not register on '#{namespace}', check if this secret file exist on this cluster")
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
    Process.kill('HUP', tunnel)
  end

  def exit_msg(msg)
    puts msg
    exit(1)
  end

  def repository(namespace)
    repository = `kubectl get #{search_by_name(namespace: namespace)} -n #{namespace} -o jsonpath='{.spec.containers[].image}'`
    if repository.nil?
      exit_msg("Repository not found on '#{namespace}', check if this namespace exist on this cluster")
    end

    _, chart, image_version = repository.split('/')
    envrionment, version = image_version.split(':')
    env = envs[envrionment]
    if chart != env[:chart]
      exit_msg('FATAL!!! This chart is not for this repository!!!')
    end

    [env, version]
  rescue StandardError
    exit_msg("FAIL on get the repository on '#{namespace},  check you are at the correct cluster'")
  end

  def exist_namespace?(namespace)
    !search_by_name(objects: 'namespace', match: "^namespace/#{namespace}").nil?
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

  def search_by_name(match: nil, objects: 'pods', namespace: 'default')
    pods = `kubectl get #{objects} -o=name -n #{namespace}`.split("\n")
    pods.select { |n| n.match(/#{match}/) }.first
  end
end

# Cli control.
class KCli < Thor
  include Helper

  class_option :namespace, type: :string, aliases: '-n', required: true, desc: 'Namespace on the clusters'

  option :version, type: :string, aliases: '-v', desc: 'Change the version, default keep the same'
  option :recreate_pods, type: :boolean, aliases: '-r', desc: 'Recreate the pods. ATTENTION this can cause downtime'
  desc 'upgrade', 'Upgrade the helm'
  def upgrade
    check!(options[:namespace])
    helm_upgrade(options[:namespace], options[:recreate_pods], options[:version])
  end

  desc 'migrate', 'Run the migration on the database'
  def migrate
    check!(options[:namespace])
    rake_migrate(options[:namespace])
  end

  option :database, type: :string, aliases: '-d', desc: 'For change from default detabase'
  desc 'dump', 'Run the mysqldump on the database'
  def dump
    check!(options[:namespace])
    mysqldump(options[:namespace], options[:database])
  end
end
KCli.start(ARGV)
