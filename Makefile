install:
	bundle install --path vendor/bundle

build:
	gem build featurevisor.gemspec

test:
	bundle exec rspec spec/
