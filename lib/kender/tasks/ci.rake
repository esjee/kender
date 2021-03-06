require 'kender/configuration'
require 'kender/github'
require 'kender/command'

# Helper method to call rake tasks without blowing up when they do not exists
# @Return: false when it could not be executed or there was some error.
def run_successfully?(tasks)
  [*tasks].all? do |task|
    Rake::Task.task_defined?(task) && Rake::Task[task].invoke
  end
end

# This is the task we want the user to use all the time.
desc "Configure and run continuous integration tests then clean up. "\
  "Can optionally be given a list of tasks to run, e.g. rake ci[rspec,cucumber] "
task :ci => ['ci:status:pending'] do |_task, arguments|
  begin
    Rake::Task["ci:config"].invoke
    Rake::Task["ci:run"].invoke(*arguments.extras)
    Rake::Task["ci:status:success"].invoke
  rescue Exception => e
    Rake::Task["ci:status:failure"].invoke
    # Ensure that this task still fails.
    raise e
  ensure
    Rake::Task["ci:clean"].invoke
  end
end

namespace :ci do

  # UI for the user, these are tasks the user can use
  desc "Configure the app to run continuous integration tests."
  task :config => ['ci:env', 'ci:config_project', 'ci:setup_db']

  desc "Run continuous integration tests with the current configuration. "\
    "Can optionally be given a list of tasks to run, e.g. rake ci:run[rspec,cucumber] "
  task :run =>  ['ci:env'] do |_task, arguments|
    names_of_the_commands_to_run = arguments.extras.map(&:to_sym)

    commands_to_run = if names_of_the_commands_to_run.any?
                        Kender::Command.where name: names_of_the_commands_to_run
                      else
                        Kender::Command.all
                      end

    #make sure we require all the tools we need loaded in memory
    commands_to_run.each do |command|
      command.execute
    end
  end

  desc "Destroy resources created externally for the continuous integration run, e.g. drops databases"
  task :clean => ['ci:env', 'ci:drop_db']

  desc "Shows a list of all the software Kender will call when ci:run is invoked."
  task :list => ['ci:env'] do
    puts "Kender will execute the following software:"
    puts Kender::Command.all_names.join("\n")
  end

  # The following tasks are internal to us, without description, the user can not discover them
  task :env do
    if defined?(Rails)
      # Default to the 'test' environment unless otherwise specified. This
      # ensures that 'db:*' tasks are run on the correct (default) database for
      # later tasks like 'spec'.
      ENV['RAILS_ENV'] ||= 'test'
      Rails.env = ENV['RAILS_ENV']
    else
      ENV['RACK_ENV'] ||= 'test'
    end
  end

  task :config_project do
    unless run_successfully?('config:deploy')
      puts 'Your project could not be configured, a config:all task needed. Consider installing dice_bag'
    end
  end

  task :setup_db do
    if Rake::Task.task_defined?('db:create')
      if !defined?(ParallelTests)
        # Use db:schema:load instead of db:migrate because of this issue
        # https://github.com/rails/rails/issues/19001
        db_task = if File.exist?('db/schema.rb')
          'db:schema:load'
        else
          'db:migrate'
        end
        unless run_successfully?(['db:create', db_task])
          puts 'The DB could not be set up successfully.'
        end
      else
        #TODO: invoke on the task did not work. Why?
        system('bundle exec rake parallel:create')
        system('bundle exec rake parallel:prepare')
      end
    else
      puts "no databases tasks found."
    end
  end

  task :drop_db do
    if Rake::Task.task_defined?('db:drop')
      if !defined?(ParallelTests)
        unless run_successfully?('db:drop')
          puts 'The DB could not be dropped.'
        end
      else
        #TODO: invoke on the task did not work. Why?
        system('bundle exec rake parallel:drop')
      end
    else
      puts "no databases tasks found."
    end
  end

  namespace :status do

    config = Kender::Configuration.new

    task :pending do
      Kender::GitHub.update_commit_status(:pending, config)
    end
    task :success do
      Kender::GitHub.update_commit_status(:success, config)
    end
    task :failure do
      Kender::GitHub.update_commit_status(:failure, config)
    end
  end
end
