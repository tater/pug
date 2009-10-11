#!/usr/bin/ruby

# pug - Utility to backup and restore file attributes.
#
# This utility stores the mode, uid and gid information 
# of a set of files in an sqlite database. This data can 
# be used to restore these attributes if they are accidentally 
# modified with the seemingly harmless chown and chmod commands.
#
# Author: Jaime Melis <j.melis@gmail.com>

require 'find'
require 'sqlite3'
require 'optparse'
require	'pp'

# ------------------------------------------------------------
# class Documentation
# This a very simple class which prints messages illustrating
# the syntax and usage of this utility.
# ------------------------------------------------------------
class Documentation
	def self.usage
		puts <<eos
Usage: pug [options] command
Type 'pug help' for a list of commands.
eos
		exit 0
	end
	def self.invalid(command)
		puts "Unkown command: '#{command}'"
		usage
	end
end

# ------------------------------------------------------------
# class Config
# This class reads the configuration file, stores it in a 
# string and eval's it. This is just a temporary solution 
# while the Config_parser class is implemented.
# ------------------------------------------------------------
class Config
	attr_reader :path
	def initialize
		path = '' 
		eval File.new('pug.conf').read
		@path = path
	end
end

# ------------------------------------------------------------
# class File_stat
# In this utility we are going to be handling File_stat objects,
# so we have to define when two File_stat objects have the same value.
# ------------------------------------------------------------
class File_stat
	attr_accessor :filename, :uid, :gid, :mode, :type
	def initialize(filename)
		if !File.exists?(filename)
			return false
		end
		
		stat = File.new(filename).stat
		@filename = filename
		@uid = stat.uid.to_i
		@gid = stat.gid.to_i
		@mode = stat.mode.to_i
		@type = stat.ftype
	end

	def ==(other_file)
		if 	@filename == other_file.filename && @uid == other_file.uid && @gid == other_file.gid && @mode == other_file.mode && @type == other_file.type
			return true
		else
			return false
		end
	end
end

# ------------------------------------------------------------
# class Files_stat_db 
# We need to create this class to be able to create an object
# which inherits File_stat's '==' method, but it's instantiated based
# on the data of the database.
# ------------------------------------------------------------
class File_stat_db < File_stat
	def initialize(filename, uid, gid, mode, type)
		@filename = filename
		@uid = uid.to_i
		@gid = gid.to_i
		@mode = mode.to_i
		@type = type
	end
end

# ------------------------------------------------------------
# class Pug
# This is the main class which performs the actual commands
# introduced by the user.
# ------------------------------------------------------------
class Pug
	attr_accessor :verbose, :simulate
	def initialize
		@conf = Config.new
		@db = SQLite3::Database.new( "db_pug.db" )
		@db.results_as_hash = true
		@verbose = false
	end
	
	def update
		n_files=0
		@db.execute('drop table if exists files')
		@db.execute('create table files (filename key, uid integer, gid integer, mode integer, type)')
		Find.find(*@conf.path) do |filename|
			n_files+=1
			file_stat = File_stat.new(filename)
			unless @simulate
				@db.execute("insert into files values (?,?,?,?,?)", file_stat.filename, file_stat.uid, file_stat.gid, file_stat.mode, file_stat.type) 
			end
		end
		if @verbose
			puts "#{n_files} files added to the database"
		end
  end
	
	def restore
		db_files = 0
		changed_files = 0
		non_existing_files = Array.new
		@db.execute('select * from files') do |row|
			db_files+=1
			filename = row['filename']
			if File.exists?(filename)
				db_file = File_stat_db.new(filename, row['uid'], row['gid'], row['mode'], row['type'])
				real_file = File_stat.new(filename)
				if db_file != real_file
					changed_files += 1
					print "#{filename}"
				
					if db_file.uid != real_file.uid || db_file.gid != real_file.gid
						print "\towner/group: #{real_file.uid}/#{real_file.gid} => #{db_file.uid}/#{db_file.gid}"
						File.chown(db_file.uid,db_file.gid,filename) unless @simulate
					end

					if db_file.mode != real_file.mode
						db_mode = sprintf('%o',db_file.mode)
						real_mode = sprintf('%o',real_file.mode)
						print "\tperms #{real_mode} => #{db_mode}"
						File.chmod(db_file.mode,filename) unless @simulate
					end
					puts ''
				end # db_file != real_file
			else
				non_existing_files.push(filename)
			end # File.exists?(filename)
		end # do |row|
		
		if verbose
			puts '' if changed_files > 0
			puts 'Summary'
			puts '-------'
			puts "Files in the database: #{db_files}"
			puts "Changed files: #{changed_files}"
			puts "Files not found: #{non_existing_files.length||0}"
		end
	end # restore


	def difference
		#contruyo 2 arrays
		local_files = Array.new
		Find.find(*@conf.path) do |filename|
			local_files.push(filename)
		end

		db_files = Array.new
		@db.execute('select filename from files') do |row|
			db_files.push(row['filename'])	
		end

		# Ficheros que estan en local pero no en la base de datos:
		local_exclusive = local_files - db_files
		puts "Ficheros que estan en local pero no en la base de datos: #{local_exclusive.length}"
		local_exclusive.each {|i| puts '* ' + i}
		puts ''
		# Ficheros que estan en la base de datos pero no local
		db_exclusive = db_files - local_files
		puts "Ficheros que estan en la base de datos pero no local: #{db_exclusive.length}"
		db_exclusive.each {|i| puts '* ' + i}

		
	end
end # File_database

# ------------------------------------------------------------
# class Command_parser
# This is a very basic class which parses the command entered
# by the user and runs the corresponding method of class Pug
# ------------------------------------------------------------
class Command_parser
	def initialize
		@pug = Pug.new
		@options = parse_options
		@command = parse_command
	end
	
	def parse_command
		if ARGV.length != 1
			Documentation.usage
		end
		return ARGV[0]
	end
	
	def parse_options
		options = Hash.new
		begin
			OptionParser.new do |opts|
				opts.banner = "Usage: pug [options]"
				opts.on("-v", "--verbose", "verbose") do |v|
					@pug.verbose = true
				end
				opts.on("-s", "--simulate", "simulate") do |v|
					@pug.simulate = true
				end
			end.parse!
		rescue OptionParser::InvalidOption => e
			puts e.message
			Documentation.usage
		end
		return options
	end
	
	def run(command=nil)
		command ||= @command
		case command
			when 'help'
				Documentation.usage
			when 'update'
				@pug.update
			when 'restore'
				@pug.restore
			when 'diff'
				@pug.difference
			else
				Documentation.invalid(command)
		end	
	end
end

# ------------------------------------------------------------
# Main program
# ------------------------------------------------------------
pug_cmd = Command_parser.new
pug_cmd.run



	
