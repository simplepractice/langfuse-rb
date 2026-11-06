# frozen_string_literal: true

require "json"

module Langfuse
  # Reads local installation records without reading skill contents or using the network.
  # @api private
  class SkillDiscovery
    LOCK_FILE = "langfuse-skills.lock"
    private_constant :LOCK_FILE

    def initialize(dir:, logger:)
      @root = File.absolute_path(dir)
      @logger = logger
    end

    def discover
      candidates = directory_entries
      return [] unless candidates

      locked = locked_skills
      candidates.each_with_object({}) do |name, available|
        directory = File.join(@root, name)
        next if name.start_with?(".") || !skill_directory?(directory)

        skill = locked.fetch(directory) { { name: name } }
        next unless unique_name?(skill[:name], available)

        available[skill[:name]] = skill
      end.values
    end

    private

    def directory_entries
      return nil unless stat_if_exists(@root)

      Dir.children(@root).sort
    rescue SystemCallError => e
      @logger.warn("Could not read skills directory #{@root}. No skills discovered: #{e.message}")
      nil
    end

    def stat_if_exists(path)
      File.stat(path)
    rescue Errno::ENOENT
      nil
    end

    def skill_directory?(directory)
      stat_if_exists(directory)&.directory? && stat_if_exists(File.join(directory, "SKILL.md"))&.file?
    rescue SystemCallError => e
      @logger.warn("Skipping skill directory #{directory}: could not inspect files: #{e.message}")
      false
    end

    def unique_name?(name, available)
      if name.length > 128
        @logger.warn("Skipping skill #{name}: name exceeds 128 characters.")
      elsif available.key?(name)
        @logger.warn("Skipping duplicate skill name #{name}.")
      else
        return true
      end
      false
    end

    def locked_skills
      file = [File.join(@root, LOCK_FILE), File.join(Dir.pwd, LOCK_FILE)].find { |path| stat_if_exists(path) }
      return {} unless file

      read_lock(file)
    rescue SystemCallError, IOError, ArgumentError, JSON::ParserError => e
      @logger.warn("Could not read skill lockfile for #{@root}. Using directory names without versions: #{e.message}")
      {}
    end

    def read_lock(file)
      file_stat = stat_if_exists(file)
      return {} unless file_stat

      raise ArgumentError, "Invalid skill lockfile #{file}." unless file_stat.file?

      value = JSON.parse(File.read(file, encoding: "UTF-8"))
      raise ArgumentError, "Unsupported or invalid skill lockfile #{file}." unless valid_lock?(value)

      value["skills"].each_with_object({}) do |skill, locked|
        unless valid_locked_skill?(skill)
          @logger.warn("Skipping invalid skill entry in #{file}.")
          next
        end
        path = File.absolute_path(skill["path"], File.dirname(file))
        locked[path] = { name: skill["name"], version: skill["version"] }
      end
    end

    def valid_lock?(value)
      value.is_a?(Hash) && value["lockVersion"].is_a?(Integer) && value["skills"].is_a?(Array)
    end

    def valid_locked_skill?(skill)
      return false unless skill.is_a?(Hash)

      path, name, version = skill.values_at("path", "name", "version")
      valid_skill_path?(path) && name.is_a?(String) && (1..128).cover?(name.length) &&
        version.is_a?(Integer) && (1..2_147_483_647).cover?(version)
    end

    def valid_skill_path?(path)
      path.is_a?(String) && !path.empty? && !path.include?("\0")
    end
  end
end
