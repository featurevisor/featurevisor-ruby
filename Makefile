install:
	bundle install

build:
	gem build featurevisor.gemspec

test:
	bundle exec rspec spec/
