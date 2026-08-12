# frozen_string_literal: true

# Regression guard for the combined pubid-structured index-v2 published by this
# repository. Both ITU sectors serialize to the same `pubid:itu` shape and share a
# single flat `data/` folder (ITU-R = `data/itu-r-*`, ITU-T = `data/itu-t-*`), so
# one index holds them together. This exercises
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
      "ITU-R BO.600-1" => "data/itu-r-bo-600-1.yaml",
      "ITU-R P.838-3" => "data/itu-r-p-838-3.yaml",
      "ITU-R BS.2295-5" => "data/itu-r-bs-2295-5.yaml",
      "ITU-R 234-1/7:" => "data/itu-r-234-1-7.yaml", # Question
      "ITU-R 23.HDB" => "data/itu-r-23-hdb.yaml",    # Handbook
    }.each do |ref, file|
      it "resolves #{ref} to #{file}" do
        row = index.search(ref).max_by { |i| i[:id].to_s[/-(\d+)\D*\z/, 1].to_i }
        expect(row).not_to be_nil
        expect(row[:file]).to eq(file)
      end
    end

    it "resolves an ITU-T ref to its data/itu-t-*.yaml file" do
      # Both sectors live under the same flat data/ folder; prove ITU-T rows
      # resolve there too (Recommendation T.0's editions).
      files = index.search("ITU-T T.0").map { |i| i[:file] }
      expect(files).not_to be_empty
      expect(files).to all(start_with("data/itu-t-t-0-"))
      expect(files).to include("data/itu-t-t-0-10-1976.yaml")
    end

    it "keeps every :file under the flat data/ folder" do
      # After the data-r/ + data-t/ merge, no row may reference the old split
      # sector folders — the CLI index scan only sees <repo>/data.
      files = rows.map { |r| r[:file] }
      expect(files).to all(start_with("data/"))
      expect(files.grep(%r{\Adata-[rt]/})).to be_empty
    end

    it "excludes the data files of skipped malformed/series-level ids" do
      # "ITU-R BT-1543-1" (dash instead of dot) is unmodelled and skipped, so its
      # data file must not be referenced by any row.
      files = rows.map { |r| r[:file] }
      expect(files).not_to include("data/itu-r-bt-1543-1.yaml")
    end

    it "points every row at a data file that exists" do
      # A row whose file was deleted 404s for every consumer, which is worse than
      # an unindexed file (that one is merely unreachable).
      dangling = rows.map { |r| r[:file] }.uniq.reject { |f| File.exist?(File.join(ROOT, f)) }
      expect(dangling).to be_empty, "index rows without a data file: #{dangling.first(3).inspect}"
    end

    it "indexes the (V##) and labelled-Annex ITU-T forms" do
      # Both forms were harvested but unindexed until pubid #320 parsed them —
      # ~260 records that existed on disk and were unreachable through the index.
      files = rows.map { |r| r[:file] }
      expect(files).to include("data/itu-t-h-264-v14-08-2021.yaml")
      expect(files.grep(/-annex-/).size).to be > 100
    end
  end

  describe "record depth" do
    # The 2026-08-09 crawl published ITU-T records carrying only docid/title/
    # date/source/doctype, because it ran against a relaton that predated the
    # enriched DataParserT — and nothing here noticed. `place: Geneva` is set
    # unconditionally by the enriched parser (outside its best-effort enrichment
    # rescue), so it is the marker for "written by the enriched harvester";
    # `contributor:` additionally requires the per-record detail fetch to have
    # succeeded, so it is the marker for "enrichment was not throttled away".
    let(:sample) { Dir["#{ROOT}/data/itu-t-*.yaml"].sample(200) }

    it "publishes ITU-T records built by the enriched harvester" do
      thin = sample.reject { |f| File.read(f, encoding: "UTF-8").include?("city: Geneva") }
      expect(thin).to be_empty, "records missing the enriched fields: #{thin.first(3).inspect}"
    end

    it "keeps enrichment on the vast majority of ITU-T records" do
      enriched = sample.count { |f| File.read(f, encoding: "UTF-8").include?("\ncontributor:") }
      expect(enriched).to be >= (sample.size * 0.9)
    end
  end

  describe "on-disk layout" do
    it "stores both sectors under a single flat data/ folder" do
      expect(Dir["#{ROOT}/data/itu-r-*.yaml"]).not_to be_empty
      expect(Dir["#{ROOT}/data/itu-t-*.yaml"]).not_to be_empty
    end

    it "no longer keeps the split data-r/ and data-t/ folders" do
      expect(Dir.exist?("#{ROOT}/data-r")).to be false
      expect(Dir.exist?("#{ROOT}/data-t")).to be false
    end
  end
end
