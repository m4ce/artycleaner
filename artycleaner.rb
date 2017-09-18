#!/usr/bin/env ruby

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
    opts.on("-c", "--config <PATH>", "Configuration file (default: #{options['config_file']})") do |config_file|
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
  config = YAML::load_file(options['config_file'])
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

      artifactory.docker_images(repo_key: repo_key).each do |image_name|
        logger.info("Processing image [#{image_name}]")

        to_keep = []
        to_delete = []

        artifactory.docker_tags(repo_key: repo_key, image_name: image_name).each do |image_tag|
          next if reserved.include?(image_tag)

          logger.info("Processing image tag [#{image_tag}]")

          tag_path = File.join(image_name, image_tag)
          tag_stats = artifactory.file_stat(repo_key: repo_key, path: File.join(tag_path, 'manifest.json'))
          tag_info = artifactory.file_info(repo_key: repo_key, path: File.join(tag_path, 'manifest.json'))

          skip = false
          if cfg['exclude_pattern'] and cfg['exclude_pattern'].size > 0
            cfg['exclude_pattern'].each do |excl|
              if Regexp.new(excl).match(image_name)
                skip = true
                break
              end
            end
          end

          if cfg['include_pattern'] and cfg['include_pattern'].size > 0
            cfg['include_pattern'].each do |incl|
              if Regexp.new(inc).match(image_name)
                skip = false
                break
              end
            end
          end

          if skip
            logger.info("Docker image '#{image_name}' will be excluded from purge")
            next
          end

          if cfg['exclude_tags'] and cfg['exclude_tags'].size > 0
            cfg['exclude_tags'].each do |excl|
              if Regexp.new(excl).match(image_tag)
                skip = true
                break
              end
            end
          end

          if cfg['include_tags'] and cfg['include_tags'].size > 0
            cfg['include_tags'].each do |incl|
              if Regexp.new(inc).match(image_tag)
                skip = false
                break
              end
            end
          end

          if skip
            logger.info("Image tag '#{image_tag}' will be excluded from purge")
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
          to_delete.sort_by! { |i| i['timestamp'] }.reverse!
          to_keep += to_delete.shift(tags_needed)
        end

        to_delete.map! { |i| i['path'] }

        if to_keep.size < cfg['keep_tags']
          logger.info("Skipping purge for image #{image_name} - minimum number of tags to keep not met")
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
            logger.info("Nothing to delete for image #{image_name}")
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
