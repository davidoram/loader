Introduction
------------

loader - a tool for creating projects templates containing couchdb documents of various kinds, and then
uploading them to your couchdb database

Pre-requisites
--------------

U*ix, ruby 1.9+, curl

gem install yajl

Usage
-----

To see options

	loader.rb --help
	
To create an empty design document 'foo'

	loader.rb -c ddoc foo
	

This creates a set of design document template files under directory 'foo\'. Edit them to your needs. 

To upload your 'foo' design document to local couchdb instance with username/password

	loader.rb -d http://username:password@127.0.0.1:5984/testdb -c push x

