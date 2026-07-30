# frozen_string_literal: true

# Regression guard for the combined pubid-structured index-v2 published by this
# repository. Both ITU sectors (ITU-R in data-r/, ITU-T in data-t/) serialize to
# the same `pubid:itu` shape, so one index holds them together. This exercises
# the exact acceptance the released Relaton::Itu flavor applies: the index must
# load through Relaton::Index (pubid_class: ::Pubid::Itu::Identifier) without
# InvalidIndexError, its rows must round-trip, and refs must resolve to their
# data files.
RSpec.describe "index-v2.yaml" do
  let(:index_file) { File.join(ROOT, "index-v2.yaml") }

  it "exists" do
    expect(File.exist?(index_file)).to be true
  end

  describe "contents" do
    # Load through the SAME loader the consumer (hit_collection) uses. This raises
    # Relaton::Index::FileIO::InvalidIndexError if any row is unsupported.
    subject(:index) do
      Relaton::Index.find_or_create(
        :itu, file: index_file, pubid_class: ::Pubid::Itu::Identifier
      )
    end

    let(:rows) { YAML.load_file(index_file) }

    it "loads through the consumer loader without raising" do
      # index.search forces Type#index -> FileIO#read -> deserialize_id, which is
      # where an unsupported row would raise InvalidIndexError.
      expect { index.search("ITU-R P.530-19") }.not_to raise_error
    end

    it "indexes the migrated ITU-R corpus" do
      # Lower bound rather than an exact count: the index is re-derived from
      # data-r/ each crawl and grows as ITU-T rows are harvested into data-t/.
      expect(rows.size).to be >= 5000
    end

    it "gives every row a number and orders them by it" do
      # Relaton::Index sorts on id.root.number.to_s. Nested ITU-T ids (amendments,
      # supplements, corrigenda, errata) expose their own sub-number at the top
      # level and the sortable document number under a nested `base` hash, so
      # follow `base` down to the root before checking the order. Flat ids
      # (recommendations, questions, handbooks) have no `base`, so their root
      # number is the top-level one.
      root_number = lambda do |id|
        id = id["base"] while id.is_a?(Hash) && id["base"]
        id["number"]
      end
      nums = rows.map { |r| root_number.call(r[:id]) }
      expect(nums).to all(be_a(String).and(be_truthy))
      expect(nums).to eq(nums.sort), "index-v2 is not sorted by root number.to_s"
    end

    it "carries only `_type: pubid:itu:*` structured ids" do
      types = rows.map { |r| r[:id]["_type"] }.uniq
      expect(types).to all(match(/\Apubid:itu:/))
      expect(types).to include("pubid:itu:recommendation",
                               "pubid:itu:question",
                               "pubid:itu:handbook")
    end

    # Every row's id must round-trip: from_hash(hash).to_hash == hash. This is the
    # guard both the producer (crawler) and the index loader enforce.
    it "round-trips every id hash" do
      offenders = rows.reject do |r|
        hash = r[:id]
        ::Pubid::Itu::Identifier.from_hash(hash).to_hash == hash
      end
      expect(offenders).to be_empty, "non-round-tripping rows: #{offenders.first(3).inspect}"
    end

    {
      "ITU-R BO.600-1" => "data-r/itu-r-bo-600-1.yaml",
      "ITU-R P.838-3" => "data-r/itu-r-p-838-3.yaml",
      "ITU-R BS.2295-5" => "data-r/itu-r-bs-2295-5.yaml",
      "ITU-R 234-1/7:" => "data-r/itu-r-234-1-7.yaml", # Question
      "ITU-R 23.HDB" => "data-r/itu-r-23-hdb.yaml",    # Handbook
    }.each do |ref, file|
      it "resolves #{ref} to #{file}" do
        row = index.search(ref).max_by { |i| i[:id].to_s[/-(\d+)\D*\z/, 1].to_i }
        expect(row).not_to be_nil
        expect(row[:file]).to eq(file)
      end
    end

    it "excludes the data files of skipped malformed/series-level ids" do
      # "ITU-R BT-1543-1" (dash instead of dot) is unmodelled and skipped, so its
      # data file must not be referenced by any row.
      files = rows.map { |r| r[:file] }
      expect(files).not_to include("data-r/itu-r-bt-1543-1.yaml")
    end
  end
end
