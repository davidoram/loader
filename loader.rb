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

DOCUMENT_TEMPLATE =<<END_OF_TEMPLATE
{
  "_id":"<%= id %>",
  "pet" : "<%= ['dog','cat'].sample %>",
  "hobbies": [
    <% separator = '' %>
    <% ['fishing','cycling','rugby','cricket','baseball','softball','reading','cinema','judo'].sample(3).each do |hobby| %>
        <%= separator %>"<%= hobby %>"
        <% separator = ',' %>
    <% end %>  
   ]
}
END_OF_TEMPLATE

def create_skeleton_docs(files)
  files.each do |a_file|
    create_a_skeleton_doc a_file
  end
end

# 
# Create a skeleton (regular) document project
#
def create_a_skeleton_doc(filename)
  if File.exists? filename
    puts "Error: file '#{filename}' already exists, try a different name"
    exit 1
  end
  id = filename.gsub /\.json$/, ''
  puts "Created skeleton document : #{filename} with id: #{id}"
  f = File.new(filename,  File::CREAT|File::TRUNC|File::RDWR, 0644)
  f.puts(ERB.new(DOCUMENT_TEMPLATE).result(binding))
  f.close
end


#
# Valid subdirectories
#
DDOC_SUBDIRS = %w{ _design _design/views }

#
# File templates are erb strings
#

PET_MAP_FN_TEMPLATE = <<END_OF_SAMPLE
/* 
 * This is a sample view function - output each person with key being whether they prefer dogs or cats
 */ 
function(doc) {
  if(doc.pet) {
    emit("pet", doc.pet);
  }
}
END_OF_SAMPLE

HOBBIES_MAP_FN_TEMPLATE = <<END_OF_SAMPLE
/* 
 * This is a sample view function - output 1 row for each hobby a person has 
 */ 
function(doc) {
  if(doc.hobbies) {
    doc.hobbies.forEach(function(hobby) {
      emit(hobby, 1);
    });
  }
}
END_OF_SAMPLE

HOBBIES_REDUCE_FN_TEMPLATE = <<END_OF_SAMPLE
/* 
  This is a sample reduce function. 
  Outputs each hobby with count of documents that use them 
*/ 
function(keys, values) {
  return sum(values);
}
END_OF_SAMPLE


DESIGN_DOC_TEMPLATE=<<END_OF_TEMPLATE
{
  "_id" : "<%= id %>",
  <% if rev %>
    "_rev": "<%= rev %>",
  <% end %>
  "language": "javascript",
  "views" : {
    <% view_separator = '' %>
    <% views.each_index do |idx| %>
      <%= view_separator %><% view_separator = ',' %>
      <% view = views[idx] %>
      "<%= view[:name] %>": {
        <% if view.has_key? :map_fn %>"map" : <%= view[:map_fn] %><% end %>
      <% if view.has_key? :reduce_fn %>,"reduce" : <%= view[:reduce_fn] %><% end %>
      }
    <% end %> 
  }
}
END_OF_TEMPLATE

DDOC_FILE_TEMPLATES = {
  '_design/_id' => "_design/<%= project_dir %>",
  '_design/views/pets/map.js' => PET_MAP_FN_TEMPLATE,
  '_design/views/hobbies/map.js' => HOBBIES_MAP_FN_TEMPLATE,
  '_design/views/hobbies/reduce.js' => HOBBIES_REDUCE_FN_TEMPLATE,
}

# 
# Create a skeleton design document project
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
# Use curl to push a document up to the server
# id is of the form '_design/moo' for a design document, or 'abcd' for a regulsr document
# 
def curl_put(database_url, id, document_text)
  tmp_file = "/tmp/loader_#{Kernel.rand}.tmp"
  f = File.new(tmp_file,File::CREAT|File::TRUNC|File::RDWR, 0644)
  f.puts document_text
  f.close
  
  #puts "curl -s -X PUT #{database_url}/#{id} -d @#{tmp_file}"
  output_json = `curl -s -X PUT #{database_url}/#{id} -d @#{tmp_file}`
  exit_status = $?
  if exit_status != 0
    puts "ERROR: Command returned #{exit_status}"
    puts "       curl -s -X PUT #{database_url}/#{id}  -d @#{tmp_file}"
    puts "Output: #{output_json}"
    exit 1
  end
  output = JSON.parse(output_json)
  if !output.has_key? 'ok' or ! output['ok']
    puts "ERROR: Couchdb returned error"
    puts "Sending contents of : #{tmp_file}"
    puts "Output: #{output_json}"
    exit 1
  end
  FileUtils.rm tmp_file
end

#
# Return the revision # of a document or nil if none
#
def get_revision(database_url, id)
  output_json = `curl -s -X GET #{database_url}/#{id}`
  exit_status = $?
  if exit_status != 0
    puts "ERROR: Command returned #{exit_status}"
    puts "       curl -s -X GET #{database_url}/#{id}"
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

  if !Dir.exists? project_dir + File::SEPARATOR + DDOC_SUBDIRS[0]
    puts "Error: #{project_dir + File::SEPARATOR + SUBDIRS[0]} doesnt exist, try passing in the project"
    exit 1
  end

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
      view[:reduce_fn] = str = Yajl::Encoder.encode(IO.binread(reduce_filename))
    end
    views << view
  end
  #puts views.inspect
  curl_put(database_url, id, ERB.new(DESIGN_DOC_TEMPLATE).result(binding))
end

#
# Push bunch of files
#
def push_doc(files, database_url)
  # Push each file
  files.each do |a_file|
    push_a_doc a_file, database_url
  end
end

#
# Push a single document file
#
def push_a_doc(file, database_url)
  content = IO.binread(file)
  doc = JSON.parse(content)
  if !doc.has_key? '_id'
    puts "ERROR: Document #{file} missing '_id'"
    exit 1
  end
  puts "Push document : #{file} to #{database_url}/#{doc['_id']}"
  rev = get_revision(database_url, doc['_id'])
  
  # If got a revision in the db, place in back in the doc so we can update
  if rev
    doc['_rev'] = rev
    content = JSON.generate doc
  end
  curl_put(database_url, doc['_id'], content)
end



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

  opts.on("-c", "--command COMMAND [arg]", "Run the command, which can one of:" +
                                           "\n\t'ddoc dir' to creates an empty design document project, pass the dir to create," +
                                           "\n\t'pddoc dir' push the design document in dir to the server ," +
                                           "\n\t'doc file [file ...]' to create an empty document, in file" +
                                           "\n\t'pdoc  [file ...]' push documents to the server ,") do |cmd|
    options.command = cmd
  end

end
opt_parser.parse!(ARGV)

  
#
# Start work
#
case options.command
when 'pddoc'
  if options.database == ''
    puts "Error: Missing database argument"
    exit 1
  end
  if ARGV.size == 0
    push_ddoc('.', options.database)
  else
    push_ddoc(ARGV[0], options.database)
  end

when 'pdoc'
  if options.database == ''
    puts "Error: Missing database argument"
    exit 1
  end
  push_doc(ARGV, options.database)

when 'ddoc'
  if ARGV.size != 1
    puts "Error: Missing project directory argument"
    exit 1
  end
  create_skeleton_ddoc(ARGV[0])
when 'doc'
  if ARGV.size < 1
    puts "Error: Missing file(s) arguments"
    exit 1
  end
  create_skeleton_docs(ARGV)
else
  puts "Error: Missing/Invalid command. Run #{__FILE__} --help for help"
end


