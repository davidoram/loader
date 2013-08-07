#! /usr/bin/env ruby
#
# CouchDB file loader
#
require 'optparse'
require 'ostruct'
require 'base64'
require 'fileutils'
require 'erb'
require "json"
require 'yajl'
require 'tmpdir'

# The options specified on the command line will be collected in *options*.
# We set default values here.
options = OpenStruct.new
options.database = ''
options.command = ''
  
opt_parser = OptionParser.new do |opts|
  opts.banner = "Usage: loader.rb [options]"

  opts.on("-d", "--database DATABASE", "Load to the database eg: http://username:password@127.0.0.1:5984/testdb") do |db|
    options.database = db
  end

  opts.on("-c", "--command COMMAND [arg]", "Run the command, which can one of 'push' which pushs to the server, 'ddoc' which cretes an empty design document project, pass the name of the new project.") do |cmd|
    options.command = cmd
  end

end
opt_parser.parse!(ARGV)

#
# Valid subdirectories
#
DDOC_SUBDIRS = %w{ _design _design/views }

#
# File templates are erb strings
#
sample_map_fn = <<END_OF_SAMPLE
/* This is a sample view function */ 
function(doc) {
  if(doc.date && doc.title) {
    emit(doc.date, doc.title);
  }
}  
END_OF_SAMPLE

sample_reduce_fn = <<END_OF_SAMPLE
/* This is a sample reduce function */ 
function(doc) {
  if(doc.date && doc.title) {
    emit(doc.date, doc.title);
  }
}  
END_OF_SAMPLE

sample_document_1 =<<END_OF_SAMPLE
{
  "_id":"biking",

  "title":"Biking",
  "body":"My biggest hobby is mountainbiking. The other day...",
  "date":"2009/01/30 18:04:11"
}
END_OF_SAMPLE

sample_document_2 =<<END_OF_SAMPLE
{
  "_id":"bought-a-cat",

  "title":"Bought a Cat",
  "body":"I went to the the pet store earlier and brought home a little kitty...",
  "date":"2009/02/17 21:13:39"
}
END_OF_SAMPLE

DESIGN_DOC_TEMPLATE=<<END_OF_TEMPLATE
{
  "_id" : "<%= id %>",
  <% if rev %>
    "_rev": "<%= rev %>",
  <% end %>
  "views" : {
    <% views.each_index do |idx| %>
      <% view = views[idx] %>
      <% view[:separator] = '' %>
      "<%= view[:name] %>": {
      
      <% if view.has_key? :map_fn %>
        "map" : <%= view[:map_fn] %> <% view[:separator] = ',' %>
      <% end %>
      
      <% if view.has_key? :reduce_fn %>
        <%= view[:separator] %>
        <% view[:separator] = '' %>
        "reduce" : <%= view[:reduce_fn] %> <% view[:separator] = ',' %>
      <% end %>
      }<% if idx < (views.size - 1) %>,<% end %>
    <% end %>
  }
}
END_OF_TEMPLATE

DDOC_FILE_TEMPLATES = {
  '_design/_id' => "_design/<%= project_dir %>",
  '_design/views/foo/map.js' => sample_map_fn,
  '_design/views/foo/reduce.js' => sample_reduce_fn,
}

# 
# Create a skeleton project
#
def create_skeleton_ddoc(project_dir)
  if Dir.exists? project_dir
    puts "Error: #{project_dir} already exists, try a different name"
    exit 1
  end
  puts "Create skeleton design document project : #{project_dir}"
  DDOC_FILE_TEMPLATES.each do |filename, template|
    FileUtils.mkdir_p(File.dirname(project_dir + File::SEPARATOR + filename))
    f = File.new(project_dir + File::SEPARATOR + filename,  File::CREAT|File::TRUNC|File::RDWR, 0644)
    f.puts(ERB.new(template).result(binding))
    f.close
  end
end

# 
# Push the project to url
#
def push_project(project_dir, database_url)
  if !Dir.exists? project_dir + File::SEPARATOR + DDOC_SUBDIRS[0]
    puts "Error: #{project_dir + File::SEPARATOR + SUBDIRS[0]} doesnt exist, try passing in the project"
    exit 1
  end
  push_ddoc(project_dir, database_url)
end

#
# Use curl to push the ddoc up to the server
# id is of the form '_design/moo'
# 
def curl_put_ddoc(database_url, id, ddoc_text)
  tmp_file = "/tmp/loader_#{Kernel.rand}.tmp"
  f = File.new(tmp_file,File::CREAT|File::TRUNC|File::RDWR, 0644)
  f.puts ddoc_text
  f.close
  
  output_json = `curl -X PUT #{database_url}/#{id} -d @#{tmp_file}`
  exit_status = $?
  if exit_status != 0
    puts "ERROR: Command returned #{exit_status}"
    puts "       curl -X PUT #{database_url}/#{id}  -d @#{tmp_file}"
    puts "Output: #{output_json}"
    exit 1
  end
  output = JSON.parse(output_json)
  if !output.has_key? 'ok' or ! output['ok']
    puts "ERROR: Couchdb returned error"
    puts "Output: #{output_json}"
    exit 1
  end
  FileUtils.rm tmp_file
end

#
# Return the revision # of a document or nil if none
#
def get_revision(database_url, id)
  output_json = `curl -X GET #{database_url}/#{id}`
  exit_status = $?
  if exit_status != 0
    puts "ERROR: Command returned #{exit_status}"
    puts "       curl -X GET #{database_url}/#{id}"
    puts "Output: #{output_json}"
    exit 1
  end
  output = JSON.parse(output_json)
  output['_rev']
end

#
# Push a design document project
#
def push_ddoc(project_dir, database_url)
  # Build up project structure, then push it as a single design doc
  project = {}
  puts "Push design document project: #{project_dir} to #{database_url}"

  id = IO.binread(project_dir + File::SEPARATOR + "_design/_id").chomp

  rev = get_revision(database_url, id)
  # Views
  views = []
  Dir.glob(project_dir + File::SEPARATOR + "_design/views/*").each do |view_dir|
    view = {:name => File.basename(view_dir) }
    map_filename = view_dir + File::SEPARATOR + "map.js" 
    if File.file? map_filename
      view[:map_fn] = str = Yajl::Encoder.encode(IO.binread(map_filename))
    end
    reduce_filename = view_dir + File::SEPARATOR + "reduce.js" 
    if File.file? reduce_filename
      view[:reduce_fn] = Yajl::Encoder.encode(IO.binread(reduce_filename))
    end
    views << view
  end
  #puts views.inspect
  curl_put_ddoc(database_url, id, ERB.new(DESIGN_DOC_TEMPLATE).result(binding))
end
  
#
# Start work
#
case options.command
when 'push'
  if options.database == ''
    puts "Error: Missing database argument"
    exit 1
  end
  if ARGV.size == 0
    push_project('.', options.database)
  else
    push_project(ARGV[0], options.database)
  end

when 'ddoc'
  if ARGV.size != 1
    puts "Error: Missing project directory argument"
    exit 1
  end
  create_skeleton_ddoc(ARGV[0])
else
  puts "Error: Missing/Invalid command. Run #{__FILE__} --help for help"
end


