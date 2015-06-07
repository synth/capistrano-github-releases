require 'octokit'
require 'dotenv'
require 'highline'

Dotenv.load

module Dotenv
  def self.add(key_value, filename = nil)
    filename = File.expand_path(filename || '.env')
    f = File.open(filename, File.exists?(filename) ? 'a' : 'w')
    f.puts key_value
    key, value = key_value.split('=')
    ENV[key] = value
  end
end

module Version
  # Credit to: https://github.com/gregorym/bump/blob/master/lib/bump.rb
  BUMPS         = %w(major minor patch pre)
  PRERELEASE    = ["alpha","beta","rc",nil]
  OPTIONS       = BUMPS | ["set", "current"]
  VERSION_REGEX = /(\d+\.\d+\.\d+(?:-(?:#{PRERELEASE.compact.join('|')}))?)/  

  def self.next_version(current, part)
    current, prerelease = current.split('-')
    major, minor, patch, *other = current.split('.')
    case part
    when "major"
      major, minor, patch, prerelease = major.succ, 0, 0, nil
    when "minor"
      minor, patch, prerelease = minor.succ, 0, nil
    when "patch"
      patch = patch.succ
    when "pre"
      prerelease.strip! if prerelease.respond_to? :strip
      prerelease = PRERELEASE[PRERELEASE.index(prerelease).succ % PRERELEASE.length]
    else
      raise "unknown part #{part.inspect}"
    end
    version = [major, minor, patch, *other].compact.join('.')
    [version, prerelease].compact.join('-')
  end

  def self.get(repo)
    repo = Octokit.repo(repo)
    releases = repo.rels[:releases].get.data
    releases[0].tag_name
  end
end

namespace :github do
  namespace :releases do
    set :ask_release, false
    set :released_at, -> { Time.now }
    set :release_tag, -> { fetch(:released_at).strftime('%Y%m%d-%H%M%S%z') }
    set :app_version, -> {

      if version = Version.get(fetch(:github_repo))
        version = Version.next_version(version,'minor')
      else
        version = HighLine.new.ask('Application version?')
      end     
      version
    }

    set :username, -> {
      username = `git config --get user.name`.strip
      username = `whoami`.strip unless username
      username
    }

    set :release_title, -> {
      default_title = fetch(:release_tag)

      if fetch(:ask_release)
        title = HighLine.new.ask("Release Title? [default: #{default_title}]")
        title = default_title if title.empty?
        title
      else
        default_title
      end
    }

    set :release_body, -> {
      default_body = <<-MD.gsub(/^ {6}/, '').strip
        #{fetch(:changelog)}
      MD

      if fetch(:ask_release)
        body = HighLine.new.ask("Release Body?")
        "#{body + "\n" unless body.empty?}#{default_body}"
      else
        default_body
      end
    }


    set :release_comment, -> {
     url = "#{fetch(:github_releases_path)}/#{fetch(:release_tag)}"

      <<-MD.gsub(/^ {6}/, '').strip
        This change was deployed to production :octocat:
        #{fetch(:release_title)}: [#{fetch(:release_tag)}](#{url})
      MD
    }

    set :changelog, -> {
      repo = Octokit.repo(fetch(:github_repo))
      last_commit = Octokit.client.commits(repo.full_name).first
      releases = repo.rels[:releases].get.data
      previous_release = releases[0]
      comparison = Octokit.client.compare(repo.full_name, previous_release.tag_name, last_commit.sha)
      url = comparison.html_url
      msgs = comparison.commits.map{ |c| "+ #{c.commit.message}" }
      <<-MSG
        Details: #{url}
        Released at: #{fetch(:released_at).strftime('%Y-%m-%d %H:%M:%S %z')}      
        #{msgs.join("\n")}
      MSG
    }

    set :github_token, -> {
      if ENV['GITHUB_PERSONAL_ACCESS_TOKEN'].nil?
        token = HighLine.new.ask('GitHub Personal Access Token?')
        Dotenv.add "GITHUB_PERSONAL_ACCESS_TOKEN=#{token}"
      else
        ENV['GITHUB_PERSONAL_ACCESS_TOKEN']
      end
    }

    set :github_repo, -> {
      repo = "#{fetch(:repo_url)}"
      repo.match(/([\w\-]+\/[\w\-\.]+)\.git$/)[1]
    }

    set :github_releases_path, -> {
      "#{Octokit.web_endpoint}#{fetch(:github_repo)}/releases/tag"
    }

    desc 'GitHub authentication'
    task :authentication do
      run_locally do
        begin
          Octokit.configure do |c|
            c.access_token = fetch(:github_token)
          end

          rate_limit = Octokit.rate_limit!
          info 'Exceeded limit of the GitHub API request' if rate_limit.remaining.zero?
          debug "#{rate_limit}"
        rescue Octokit::NotFound
          # No rate limit for white listed users
        rescue => e
          error e.message
        end
      end
    end

    desc 'Create new release note'
    task create: :authentication do
      run_locally do
        begin
          Octokit.create_release(
            fetch(:github_repo),
            fetch(:release_tag),
            name: fetch(:release_title),
            body: fetch(:release_body),
            target_commitish: 'master',
            draft: false,
            prerelease: false
          )

          info "Release as #{fetch(:release_tag)} to #{fetch(:github_repo)} was created"
        rescue => e
          error e.message
          # invoke 'github:git:create_tag_and_push_origin'
        end
      end
    end

    desc 'Add comment for new release'
    task add_comment: :authentication do
      run_locally do
        begin
          Octokit.add_comment(
            fetch(:github_repo),
            fetch(:release_tag),
            fetch(:release_comment)
          )
          info "Comment to #{fetch(:github_repo)}/#{fetch(:release_tag)} was added"
        rescue => e
          error e.message
        end
      end
    end
  end

  namespace :git do
    desc 'Create tag for new release and push to origin'
    task :create_tag_and_push_origin do
      message = "#{fetch(:release_title)} by #{fetch(:username)}\n"
      message += "#{fetch(:github_repo)}##{fetch(:release_tag)}"

      run_locally do
        execute :git, :tag, '-am', "#{message}", "#{fetch(:release_tag)}"
        execute :git, :push, :origin, "#{fetch(:release_tag)}"
      end
    end
  end
end
