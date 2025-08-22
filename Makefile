install:
	bundle config set path 'vendor/bundle'
	bundle install

build:
	gem build featurevisor.gemspec

test:
	bundle exec rspec spec/
