require_relative 'helper'
require 'refinery/string-shaper'
require 'refinery/string-to'

class TestStringShaper < Minitest::Test
    using Refinery::StringShaper

    def test_snakize
        { 'fooBar'      => 'foo_bar',
          'FooBar'      => 'foo_bar',
          'HTTPServer'  => 'http_server',
          'IPv6Address' => 'ipv6_address',
          'foo'         => 'foo',
          'foo_bar'     => 'foo_bar',
          'getHTTPResponseCode' => 'get_http_response_code',
          'XMLHttpRequest'      => 'xml_http_request',
          'userID'              => 'user_id',
          'CO2EmissionSaved'    => 'co2_emission_saved',
          'L1Data'              => 'l1_data',
          'Base64Encode'        => 'base64_encode',
          'getV2Data'           => 'get_v2_data',
          'ABC'                 => 'abc',
        }.each {|from, to| assert_equal to, from.snakize, from }
    end

    def test_snakize_without_splitting_acronyms
        assert_equal 'httpserver', 'HTTPServer'.snakize(split_acronyms: false)
        assert_equal 'foo_bar',    'fooBar'.snakize(split_acronyms: false)
    end

    def test_camelize
        assert_equal 'fooBar',     'foo_bar'.camelize
        assert_equal 'FooBar',     'foo_bar'.camelize(upper: true)
        assert_equal 'fooBar',     '_foo__bar_'.camelize
        assert_equal '',           '__'.camelize
        assert_equal '',           ''.camelize
    end

    def test_camelize_cannot_restore_an_acronym
        assert_equal 'httpServer', 'HTTPServer'.snakize.camelize
    end
end

class TestStringTo < Minitest::Test
    using Refinery::StringTo

    def test_to_filename_removes_separators_and_nul
        assert_equal 'a_b_c', " a/b\0c ".to_filename
    end

    def test_escapes
        assert_equal '&lt;a href=&quot;x&quot;&gt;', '<a href="x">'.to_html
        assert_equal 'a%20b%2Fc',                    'a b/c'.to_uri_component
    end
end
