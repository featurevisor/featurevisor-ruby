# frozen_string_literal: true

require 'featurevisor'
require 'net/http'
require 'json'

RSpec.describe 'README initialization' do
  let(:source) do
    readme = File.read(File.expand_path('../README.md', __dir__), encoding: 'UTF-8')
    readme.match(/## Initialization\n.*?```ruby\n(.*?)\n```/m)[1]
  end
  let(:fixture) do
    JSON.generate(schemaVersion: '2', revision: 'readme', segments: {}, variables: {},
                  features: { checkout: { hash: 'checkout', bucketBy: 'userId',
                    traffic: [{ key: 'all', segments: '*', percentage: 100_000 }] } })
  end

  def respond_with(code, body)
    response = Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new('1.1', code, 'Fixture')
    allow(response).to receive(:body).and_return(body)
    allow(Net::HTTP).to receive(:get_response)
      .with(URI('https://cdn.yoursite.com/featurevisor-all.json')).and_return(response)
  end

  it 'executes the actual snippet and evaluates the loaded feature' do
    respond_with('200', fixture)
    expect { eval(source, binding, 'README.md') }.to output(/true\n/).to_stdout
  end

  %w[302 404 503].each do |code|
    it "rejects HTTP #{code} even with valid datafile content" do
      respond_with(code, fixture)
      expect(Featurevisor).not_to receive(:create_featurevisor)
      expect { eval(source, binding, 'README.md') }.to raise_error(RuntimeError, /HTTP #{code}/)
    end
  end

  it 'propagates invalid JSON without creating an instance' do
    respond_with('200', '{')
    expect(Featurevisor).not_to receive(:create_featurevisor)
    expect { eval(source, binding, 'README.md') }.to raise_error(JSON::ParserError)
  end

  it 'propagates transport errors without creating an instance' do
    allow(Net::HTTP).to receive(:get_response).and_raise(IOError, 'connection failed')
    expect(Featurevisor).not_to receive(:create_featurevisor)
    expect { eval(source, binding, 'README.md') }.to raise_error(IOError, 'connection failed')
  end
end
