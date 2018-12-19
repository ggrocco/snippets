#!/usr/bin/env ruby

require 'optparse'
require 'yaml'

class Helper
  class << self
    def envs
      @envs ||= Dir.glob("chart/#{chart_name}/values*.yaml").each_with_object({}) do |f, hash|
        repository = YAML.load_file(f)['image']['repository']
        _host, chart, environment = repository.split('/')
        hash[environment] = { file: f, chart: chart }
      end
    end

    def helm_upgrade(namespace, options)
      puts 'Upgrading helm'
      env, repo_version = repository(namespace)
      extra = options[:recreate_pods] ? ' --recreate-pods' : ''
      version = options[:version] || repo_version

      puts `helm upgrade #{namespace} ./chart/#{chart_name} -f ./#{env[:file]} --set=image.tag=#{version}#{extra}`
    end

    def check!
      exit_msg('This directory does not have a chart folder') if chart_name.nil?
      exit_msg('This directory does not have environments defined') if envs.empty?
    end

    def exit_msg(msg)
      puts msg
      exit(1)
    end

    private

    def repository(namespace)
      repository = `kubectl get $(kubectl get pod -o=name -n #{namespace} | head -1) -n #{namespace} -o jsonpath='{.spec.containers[].image}'`
      exit_msg("Repository not found on '#{namespace}', check if this namespace exist on this cluster") if repository.nil?
      _, chart, image_version = repository.split('/')
      envrionment, version = image_version.split(':')
      env = envs[envrionment]
      exit_msg('FATAL!!! This chart is not for this repository!!!') if chart != env[:chart]
      [env, version]
    rescue
      exit_msg("FAIL on get the repository on '#{namespace},  check you are at the correct cluster'")
    end

    def chart_name
      @chart_name ||= begin
                        Dir.chdir('chart') { Dir.glob('*').select {|f| File.directory? f} }.first
                      rescue
                        nil
                      end
    end
  end
end

Helper.check!

ARGV << '-h' if ARGV.empty?
options = { recreate_pods: false }
OptionParser.new do |opts|
  opts.banner = 'Usage: k_cli.rb COMMAND [options]'
  opts.separator ''
  opts.separator 'COMMAND'
  opts.separator '  upgrade, helm upgrade'

  opts.on('-n', '--namespace NAMESPACES', 'REQUIRED Namespaces to helm upgrade') do |namespace|
    options[:namespace] = namespace
  end

  opts.on('-r', '--recreate-pods', 'Recreate the pods. ATTENTION this can cause downtime!') do |v|
    options[:recreate_pods] = true
  end

  opts.on('-v', '--version VERSION', 'Change the version, default keep the same') do |version|
    options[:version] = version
  end
end.parse!

Helper.exit_msg('Needs only one COMMAND') if ARGV.size > 1
command = ARGV[0]
if command =~ /upgrade/i
  Helper.exit_msg('Namespace is required') if options[:namespace].nil?
  Helper.helm_upgrade(options[:namespace], options)
end
