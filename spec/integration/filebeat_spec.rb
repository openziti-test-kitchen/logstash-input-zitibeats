# encoding: utf-8
require "logstash/inputs/beats"
require "stud/temporary"
require "flores/pki"
require "fileutils"
require "thread"
require "spec_helper"
require "yaml"
require "fileutils"
require "flores/pki"
require_relative "../support/flores_extensions"
require_relative "../support/file_helpers"
require_relative "../support/integration_shared_context"
require_relative "../support/client_process_helpers"

FILEBEAT_BINARY = File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "vendor", "filebeat", "filebeat"))

describe "Filebeat", :integration => true do
  include ClientProcessHelpers
  include FileHelpers

  before :all do
    LogStash::Logging::Logger.configure_logging("debug") if ENV["DEBUG"] == 1

    unless File.exist?(FILEBEAT_BINARY)
      raise "Cannot find `Filebeat` binary in `vendor/filebeat`. Did you run `bundle exec rake test:integration:setup` before running the integration suite?"
    end
  end

  include_context "beats configuration"

  # Filebeat related variables
  let(:cmd) { [filebeat_exec, "-c", filebeat_config_path, "-e", "-v"] }

  let(:filebeat_exec) { FILEBEAT_BINARY }

  let(:filebeat_config) do
    {
      "filebeat" => {
        "inputs" => [{ "paths" => [log_file],  "type" => "log" }],
        "scan_frequency" => "1s"
      },
      "output" => {
        "logstash" => { "hosts" => ["#{host}:#{port}"] },
      },
      "logging" => { "level" => "debug" }
    }
  end

  let_tmp_file(:filebeat_config_path) { YAML.dump(filebeat_config) }
  before :each do
    FileUtils.rm_rf(File.join(File.dirname(__FILE__), "..", "..", "vendor", "filebeat", "data"))
    start_client
    raise 'Filebeat did not start in alloted time' unless is_alive
    sleep(20) # give some time to FB to send something
  end

  after :each do
    stop_client
  end

  ###########################################################
  shared_context "Root CA" do
    let(:root_ca) { Flores::PKI.generate("CN=root.localhost") }
    let(:root_ca_certificate) { root_ca.first }
    let(:root_ca_key) { root_ca.last }
    let_tmp_file(:root_ca_certificate_file) { root_ca_certificate }
  end

  shared_context "Intermediate CA" do
    let(:intermediate_ca) { Flores::PKI.create_intermediate_certificate("CN=intermediate.localhost", root_ca_certificate, root_ca_key) }
    let(:intermediate_ca_certificate) { intermediate_ca.first }
    let(:intermediate_ca_key) { intermediate_ca.last }
    let_tmp_file(:intermediate_ca_certificate_file) { intermediate_ca_certificate }
    let_tmp_file(:certificate_authorities_chain) { Flores::PKI.chain_certificates(root_ca_certificate, intermediate_ca_certificate) }
  end

  ############################################################
  # Actuals tests
  context "Plain TCP" do
    include_examples "send events"

    context "with large batches" do
      let(:number_of_events) { 10_000 }
      include_examples "send events"
    end

    context "without pipelining" do
      let(:filebeat_config) { config = super(); config["output"]["logstash"]["pipelining"] = 0; config }
      include_examples "send events"

      context "with large batches" do
        let(:number_of_events) { 10_000 }
        include_examples "send events"
      end
    end
  end

  context "TLS" do
    context "Server verification" do
      let(:filebeat_config) do
        super().merge({
          "output" => {
            "logstash" => {
              "hosts" => ["#{host}:#{port}"],
              "ssl" => { "certificate_authorities" => certificate_authorities }
            }
          },
          "logging" => { "level" => "debug" }
          })
      end

      let(:input_config) do
        super().merge({
          "ssl" => true,
          "ssl_certificate" => certificate_file,
          "ssl_key" => certificate_key_file
        })
      end

      let(:certificate_authorities) { [certificate_file] }
      let(:certificate_data) { Flores::PKI.generate }

      let_tmp_file(:certificate_key_file) { convert_to_pkcs8(certificate_data.last) }
      let_tmp_file(:certificate_file) { certificate_data.first }

      context "self signed certificate" do
        include_examples "send events"

        context "when specifying a cipher" do
          let(:filebeat_config) do
            super().merge({
              "output" => {
                "logstash" => {
                  "hosts" => ["#{host}:#{port}"],
                  "ssl" => {
                    "certificate_authorities" => certificate_authorities,
                    "versions" => ["TLSv1.2"],
                    "cipher_suites" => [beats_cipher]
                  }
                }
              },
              "logging" => { "level" => "debug" }
              })
          end

          let(:input_config) {
            super().merge({
              "cipher_suites" => [logstash_cipher],
              "tls_min_version" => "1.2"
            })
          }

          context "when the cipher is supported" do
            {
              #Not Working? "ECDHE-ECDSA-AES-256-GCM-SHA384" => "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
              "ECDHE-RSA-AES-256-GCM-SHA384" => "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
              #Not working? "ECDHE-ECDSA-AES-128-GCM-SHA256" => "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
              "ECDHE-RSA-AES-128-GCM-SHA256" => "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
            }.each do |b_cipher, l_cipher|
              context "with protocol: `TLSv1.2` and cipher: beats: #{b_cipher}, logstash: #{l_cipher}" do
                let(:beats_cipher) { b_cipher }
                let(:logstash_cipher) { l_cipher }
                include_examples "send events"
              end
            end

            context "when the cipher is not supported" do
              let(:beats_cipher) { "ECDHE-RSA-AES-256-GCM-SHA384" }
              let(:logstash_cipher) { "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"}

              include_examples "doesn't send events"
            end
          end
        end

        context "with TLSv1.3 client" do
          let(:filebeat_config) do
            super().merge({
              "output" => {
                "logstash" => {
                  "hosts" => ["#{host}:#{port}"],
                  "ssl" => {
                    "certificate_authorities" => certificate_authorities,
                    "versions" => ["TLSv1.3"],
                  }
                }
              },
              "logging" => { "level" => "debug" }
              })
          end
          include_examples "send events"

          context "when TLSv1.3 enforced in plugin" do
            let(:input_config) {
              super().merge({
                "tls_min_version" => "1.3"
              })
            }

            include_examples "send events"
          end
        end

        # Refactor this to use Flores's PKI instead of openssl command line
        # see: https://github.com/jordansissel/ruby-flores/issues/7
        context "with a passphrase" do

          before(:all) do
            @passphrase = "foobar".freeze

            FileUtils.mkdir_p temporary_directory = Stud::Temporary.pathname

            cert_key = ::File.join(temporary_directory, "certificate.key")
            @cert_pub = ::File.join(temporary_directory, "certificate.crt")
            @cert_key_pkcs8 = ::File.join(temporary_directory, "certificate.key.pkcs8")

            cmd = "openssl req -x509  -batch -newkey rsa:2048 -keyout #{cert_key} -out #{@cert_pub} -passout pass:#{@passphrase} -subj \"/C=EU/O=Logstash/CN=localhost\""
            unless system(cmd)
              fail "failed to run openssl command: #{$?} \n#{cmd}"
            end

            # NOTE: CentOS 7 base image (LS < 7.17) uses OpenSSL 1.0 while later is using Ubuntu 20.04 with OpenSSL 1.1.1
            # the default algorithm for `openssl pkcs8 -topk8` changed to -v2 which Java does not support (see GH-443)
            cmd = "openssl pkcs8 -topk8 -in #{cert_key} -out #{@cert_key_pkcs8} -v1 PBE-SHA1-RC2-128 -passin pass:#{@passphrase} -passout pass:#{@passphrase}"
            unless system(cmd)
              fail "failed to run openssl command: #{$?} \n#{cmd}"
            end
          end

          let(:certificate_authorities) { [ @cert_pub ] }

          let(:input_config) do
            super().merge("ssl_key_passphrase" => @passphrase, "ssl_key" => @cert_key_pkcs8, "ssl_certificate" => @cert_pub)
          end

          include_examples "send events"
        end
      end


      context "CA root" do
        include_context "Root CA"

        let_tmp_file(:certificate_key_file) { convert_to_pkcs8(certificate_data.last) }
        let_tmp_file(:certificate_file) { certificate_data.first }

        context "directly signed client certificate" do
          let(:certificate_authorities) { [root_ca_certificate_file] }
          let(:certificate_data) { Flores::PKI.create_client_certicate("CN=localhost", root_ca_certificate, root_ca_key) }

          include_examples "send events"
        end

        context "intermediate CA signs client certificate" do
          include_context "Intermediate CA"

          let(:certificate_data) { Flores::PKI.create_client_certicate("CN=localhost", intermediate_ca_certificate, intermediate_ca_key) }
          let(:certificate_authorities) { [certificate_authorities_chain] }

          include_examples "send events"
        end
      end

      context "Client verification / Mutual validation" do
        let(:filebeat_config) do
          super().merge({
            "output" => {
              "logstash" => {
                "hosts" => ["#{host}:#{port}"],
                "ssl" => {
                  "certificate_authorities" => certificate_authorities,
                  "certificate" => certificate_file,
                  "key" => certificate_key_file
                }
              }
            },
            "logging" => { "level" => "debug" }
            })
        end

        let(:input_config) do
          super().merge({
            "ssl" => true,
            "ssl_certificate_authorities" => certificate_authorities,
            "ssl_certificate" => server_certificate_file,
            "ssl_key" => server_certificate_key_file,
            "ssl_verify_mode" => "force_peer"
          })
        end

        context "with a self signed certificate" do
          let(:certificate_authorities) { [certificate_file] }
          let(:certificate_data) { Flores::PKI.generate }
          let_tmp_file(:certificate_key_file) { convert_to_pkcs8(certificate_data.last) }
          let_tmp_file(:certificate_file) { certificate_data.first }
          let_tmp_file(:server_certificate_file) { certificate_data.first }
          let_tmp_file(:server_certificate_key_file) { convert_to_pkcs8(certificate_data.last) }

          include_examples "send events"
        end

        context "CA root" do
          include_context "Root CA"

          let_tmp_file(:server_certificate_file) { server_certificate_data.first }
          let_tmp_file(:server_certificate_key_file) { convert_to_pkcs8(server_certificate_data.last) }
          let_tmp_file(:certificate_file) { certificate_data.first }
          let_tmp_file(:certificate_key_file) { convert_to_pkcs8(certificate_data.last) }

          context "directly signed client certificate" do
            let(:certificate_authorities) { [root_ca_certificate_file] }
            let(:certificate_data) { Flores::PKI.create_client_certicate("CN=localhost", root_ca_certificate, root_ca_key) }
            let(:server_certificate_data) { Flores::PKI.create_client_certicate("CN=localhost", root_ca_certificate, root_ca_key) }

            include_examples "send events"
          end

          context "intermediate create server and client certificate" do
            include_context "Intermediate CA"

            let(:certificate_data) { Flores::PKI.create_client_certicate("CN=localhost", intermediate_ca_certificate, intermediate_ca_key) }
            let(:server_certificate_data) { Flores::PKI.create_client_certicate("CN=localhost", intermediate_ca_certificate, intermediate_ca_key) }
            let(:certificate_authorities) { [intermediate_ca_certificate_file] }

            include_examples "send events"
          end

          context "with multiples different CA, and unrelated CA appear first in the file" do
            include_context "Intermediate CA"

            let(:secondary_ca) { Flores::PKI.generate }
            let(:secondary_ca_key) { secondary_ca.last }
            let(:secondary_ca_certificate) { secondary_ca.first }
            let_tmp_file(:ca_file) { Flores::PKI.chain_certificates(secondary_ca_certificate, intermediate_ca_certificate) }

            let(:certificate_data) { Flores::PKI.create_client_certicate("CN=localhost", intermediate_ca_certificate, intermediate_ca_key) }
            let(:server_certificate_data) { Flores::PKI.create_client_certicate("CN=localhost", intermediate_ca_certificate, intermediate_ca_key) }
            let(:certificate_authorities) { [ca_file] }

            include_examples "send events"
          end

          context "and Secondary CA multiples clients" do
            context "with CA in different files" do
              let(:secondary_ca) { Flores::PKI.generate }
              let(:secondary_ca_key) { secondary_ca.last }
              let(:secondary_ca_certificate) { secondary_ca.first }
              let_tmp_file(:secondary_ca_certificate_file) { secondary_ca.first }

              let(:secondary_client_certificate_data) { Flores::PKI.create_client_certicate("CN=localhost", secondary_ca_certificate, secondary_ca_key) }
              let_tmp_file(:secondary_client_certificate_file) { secondary_client_certificate_data.first }
              let_tmp_file(:secondary_client_certificate_key_file) { convert_to_pkcs8(secondary_client_certificate_data.last) }
              let(:certificate_authorities) { [root_ca_certificate_file, secondary_ca_certificate_file] }
              let(:certificate_data) { Flores::PKI.create_client_certicate("CN=localhost", root_ca_certificate, root_ca_key) }

              let(:server_certificate_data) { Flores::PKI.create_client_certicate("CN=localhost", root_ca_certificate, root_ca_key) }

              context "client from primary CA" do
                include_examples "send events"
              end

              context "client from secondary CA" do
                let(:filebeat_config) do
                  super().merge({
                    "output" => {
                      "logstash" => {
                        "hosts" => ["#{host}:#{port}"],
                        "ssl" => {
                          "certificate_authorities" => certificate_authorities,
                          "certificate" => secondary_client_certificate_file,
                          "key" => secondary_client_certificate_key_file
                        }
                      }
                    },
                    "logging" => { "level" => "debug" }
                    })
                end

                include_examples "send events"
              end
            end
          end
        end
      end
    end
  end
end
