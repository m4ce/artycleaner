#!/usr/bin/env ruby
#
# artycleaner.rb
#
# Author: Matteo Cerutti <matteo.cerutti@hotmail.co.uk>
#

require 'yaml'
require 'optparse'
require 'chronic_duration'
require 'deep_merge'
require 'logger'
require 'artifactory/client'

class Hash
  def symbolize_keys
    {}.tap do |h|
      self.each do |key, value|
      h[key.to_sym] = case value
          when Hash
            value.symbolize_keys
          when Array
            value.map { |v| v.symbolize_keys }
          else
            value
        end
      end
    end
  end
end

options = {}
begin
  OptionParser.new do |opts|
    options['config_file'] = File.join(__dir__, 'artycleaner.yaml')
    opts.on("-c", "--config", "Configuration file (default: #{options['config_file']})") do |config_file|
      options['config_file'] = config_file
    end

    options['dryrun'] = false
    opts.on("--dryrun", "Dry-run mode") do
      options['dryrun'] = true
    end

    options['log_level'] = 'INFO'
    opts.on("--log_level LEVEL", ['DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL', 'UNKNOWN'], "Logging level") do |level|
      options['log_level'] = level
    end
  end.parse!
rescue
  STDERR.puts($!)
  exit 1
end

begin
  config = YAML::load_file(File.open(options['config_file']))
rescue
  STDERR.puts("Failed to load configuration - #{$!}")
  exit 1
end

logger = Logger.new(STDOUT)
logger.level = Logger.const_get(options['log_level'])
logger.formatter = proc do |severity, datetime, progname, msg|
  "#{datetime.strftime('[%Y-%m-%d %H:%M:%S]')} - #{severity}: #{msg}\n"
end
STDOUT.sync = true

reserved = [
  '_uploads'
]

ret = {
  'to_delete' => []
}

# Initialize client
artifactory = Artifactory::Client.new(config['api'].symbolize_keys)

logger.info("Default configuration: [#{config['defaults'].inspect}]")

config['repos'].each do |repo_key, repo_cfg|
  # look up repo
  repo_info = artifactory.get_repo(key: repo_key)

  # merge default configuration
  cfg = repo_cfg.deep_merge(config['defaults'])

  # compute purge ttl for artifacts
  duration = ChronicDuration.parse(cfg['purge_ttl'])
  purge_ttl = duration > 0 ? Time.now - duration : nil

  logger.info("Processing repository [#{repo_key}]")
  logger.info("Repository configuration [#{cfg.inspect}]")

  case repo_info['packageType']
    when "docker"
      docker_image = {}
      artifactory.file_list(repo_key: repo_key, list_folders: true).each do |image_name, image|
        if image['folder']
          docker_image['name'] = image_name[1..-1]
          logger.info("Processing image [#{docker_image['name']}]")

          to_keep = []
          to_delete = []

          artifactory.file_list(repo_key: repo_key, folder_path: image_name, list_folders: true).each do |tag_name, tag|
            docker_image['tag'] = tag_name[1..-1]

            next if reserved.include?(docker_image['tag'])

            logger.info("Processing image tag [#{docker_image['tag']}]")

            tag_path = File.join(image_name, tag_name)
            tag_stats = artifactory.file_stat(repo_key: repo_key, path: File.join(tag_path, 'manifest.json'))
            tag_info = artifactory.file_info(repo_key: repo_key, path: File.join(tag_path, 'manifest.json'))

            skip = false
            if cfg['exclude_pattern'] and cfg['exclude_pattern'].size > 0
              cfg['exclude_pattern'].each do |excl|
                if Regexp.new(excl).match(docker_image['name'])
                  skip = true
                  break
                end
              end
            end

            if cfg['include_pattern'] and cfg['include_pattern'].size > 0
              cfg['include_pattern'].each do |incl|
                if Regexp.new(inc).match(docker_image['name'])
                  skip = false
                  break
                end
              end
            end

            if skip
              logger.info("Docker image '#{docker_image['name']}' will be excluded from purge")
              next
            end

            if cfg['exclude_tags'] and cfg['exclude_tags'].size > 0
              cfg['exclude_tags'].each do |excl|
                if Regexp.new(excl).match(docker_image['tag'])
                  skip = true
                  break
                end
              end
            end

            if cfg['include_tags'] and cfg['include_tags'].size > 0
              cfg['include_tags'].each do |incl|
                if Regexp.new(inc).match(docker_image['tag'])
                  skip = false
                  break
                end
              end
            end

            if skip
              logger.info("Image tag '#{docker_image['tag']}' will be excluded from purge")
              next
            end

            if purge_ttl.nil? or (tag_stats['lastDownloaded'] and tag_stats['lastDownloaded'] >= purge_ttl) or (tag_info['created'] and tag_info['created'] >= purge_ttl) or (tag_info['lastModified'] and tag_info['lastModified'] >= purge_ttl)
              to_keep << tag_path
            else
              to_delete << {
                'path' => tag_path,
                'timestamp' => tag_stats['lastDownloaded'] || tag_info['created'] || tag_info['lastModified']
              }
            end
          end

          tags_needed = cfg['keep_tags'] - to_keep.size
          if tags_needed > 0 and (to_delete.size - tags_needed) > 0
            to_delete.sort_by! { |i| i['timestamp'] }.reverse
            to_keep += to_delete.shift(tags_needed)
          end

          to_delete.map! { |i| i['path'] }

          if to_keep.size < cfg['keep_tags']
            logger.info("Skipping purge for image #{docker_image['name']} - minimum number of tags to keep not met")
          else
            if to_delete.size > 0
              logger.debug("The following items will be kept: #{to_keep.join(', ')}")
              logger.debug("The following items will be deleted: #{to_delete.join(', ')}")

              to_delete.each do |path|
                if options['dryrun']
                  logger.warn("Would've deleted #{path}")
                else
                  logger.warn("Deleting #{path}")
                  artifactory.file_delete(repo_key: repo_key, path: path)
                end
              end
            else
              logger.info("Nothing to delete for image #{docker_image['name']}")
            end
          end
        end
      end

    else
      to_delete = []

      artifactory.search_usage(repo_key: repo_key, not_used_since: purge_ttl).each do |file|
        logger.info("Processing file [#{file['path']}]")

        skip = false
        if cfg['exclude_pattern'] and cfg['exclude_pattern'].size > 0
          cfg['exclude_pattern'].each do |excl|
            if Regexp.new(excl).match(file['path'])
              skip = true
              break
            end
          end
        end

        if cfg['include_pattern'] and cfg['include_pattern'].size > 0
          cfg['include_pattern'].each do |incl|
            if Regexp.new(inc).match(file['path'])
              skip = false
              break
            end
          end
        end

        if skip
          logger.info("File '#{file['path']}' will be excluded from purge")
          next
        end

        to_delete << file['path']
      end

      if to_delete.size > 0
        logger.debug("The following items will be deleted: #{to_delete.join(', ')}")

        to_delete.each do |path|
          if options['dryrun']
            logger.warn("Would've deleted #{path}")
          else
            logger.warn("Deleting #{path}")
            artifactory.file_delete(repo_key: repo_key, path: path)
          end
        end
      else
        logger.info("No files to delete for repo #{repo_key}")
      end
  end
end
