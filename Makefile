# Install the gem locally
install: build
	@echo "Installing featurevisor gem..."
	gem install featurevisor-*.gem
	@echo "Installation complete!"

# Build the gem package
build:
	@echo "Building featurevisor gem..."
	gem build featurevisor.gemspec
	@echo "Build complete! Created: featurevisor-*.gem"

# Run the test suite
test:
	@echo "Running tests..."
	bundle exec rspec spec/
	@echo "Tests completed!"

# Clean up build artifacts
clean:
	@echo "Cleaning up build artifacts..."
	rm -f featurevisor-*.gem
	@echo "Cleanup complete!"
