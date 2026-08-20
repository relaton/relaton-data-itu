# frozen_string_literal: true

# Unit guard for crawler.rb, the producer side of this dataset. index_v2_spec.rb
# checks what was published; this checks the code that decides what gets
# published — which of the two sectors is wiped before a harvest, and whether a
# collapsed crawl is allowed to reach `git add`.
#
# Both matter more since relaton #112: the ITU-R half is now crawled rather than
# preserved, so a run that loses a family deletes published records instead of
# merely failing to add new ones, and the relaton consumer reads this repo's
# `main` at runtime.
#
# No network here — DataFetcher is stubbed. The live path is exercised
# separately (see the hand-off's verification section).

require "fileutils"
require "tmpdir"

require_relative "../crawler"

RSpec.describe ItuCrawler do
  # crawler.rb addresses everything through relative globs ("data/…"), so the
  # specs chdir into a throwaway tree and build the state they describe.
  def in_tmp_repo(&block)
    Dir.mktmpdir("itu-crawler-spec") { |dir| Dir.chdir(dir, &block) }
  end

  def touch(*files)
    FileUtils.mkdir_p ItuCrawler::DATA
    files.each { |f| FileUtils.touch File.join(ItuCrawler::DATA, f) }
  end

  # A repo whose HEAD holds `files`, so the guards' `git ls-files` sees them.
  def commit(*files)
    system("git", "init", "--quiet", ".", exception: true)
    system("git", "config", "user.email", "spec@example.com", exception: true)
    system("git", "config", "user.name", "spec", exception: true)
    touch(*files)
    system("git", "add", "-A", ItuCrawler::DATA, exception: true)
    system("git", "commit", "--quiet", "-m", "fixture", exception: true)
  end

  around do |example|
    mode = ENV.fetch("RELATON_ITU_MODE", nil)
    example.run
  ensure
    ENV["RELATON_ITU_MODE"] = mode
  end

  describe ".full?" do
    it "is a full crawl by default" do
      ENV.delete "RELATON_ITU_MODE"
      expect(described_class.full?).to be true
    end

    # The wipe decision and the harvest mode must not be able to disagree: both
    # read Relaton::Itu::DataFetcher.mode.
    it "is not a full crawl under RELATON_ITU_MODE=top_up" do
      ENV["RELATON_ITU_MODE"] = "top_up"
      expect(described_class.full?).to be false
    end
  end

  describe ".harvest" do
    let(:fetcher) { instance_double(Relaton::Itu::DataFetcher, index: index) }
    let(:index) { instance_double(Relaton::Index::Type, save: nil) }

    before do
      allow(Relaton::Itu::DataFetcher).to receive(:new).and_return fetcher
      allow(fetcher).to receive(:fetch_publications)
      allow(fetcher).to receive(:fetch_recommendations)
      allow(fetcher).to receive(:index_files)
      allow(fetcher).to receive(:report_errors)
    end

    it "crawls both sectors off one fetcher, saving and reporting once" do
      in_tmp_repo do
        touch "itu-r-bo-600-1.yaml", "itu-t-a-1-10-2000.yaml"
        described_class.harvest

        expect(fetcher).to have_received(:fetch_publications).ordered
        expect(fetcher).to have_received(:fetch_recommendations).ordered
        expect(index).to have_received(:save).once
        expect(fetcher).to have_received(:report_errors).once
      end
    end

    # The ITU-R records are no longer preserved: ITU is the sole author of them,
    # which is the point of crawling it at all. Both spellings must go — a Report
    # is data/report-itu-r-* (relaton #110).
    it "wipes both sectors, both ITU-R spellings, on a full run" do
      ENV.delete "RELATON_ITU_MODE"
      in_tmp_repo do
        touch "itu-r-bo-600-1.yaml", "report-itu-r-bt-2020-1.yaml",
              "itu-t-a-1-10-2000.yaml"
        described_class.harvest

        expect(Dir["data/*.yaml"]).to be_empty
      end
    end

    # A top-up decides what to skip with DataFetcher#held?, which is a
    # File.exist? on the data file. Wiping first would make every edition look
    # missing and turn the cheap daily run back into a full crawl.
    it "keeps the ITU-R records on a top-up, and still wipes ITU-T" do
      ENV["RELATON_ITU_MODE"] = "top_up"
      in_tmp_repo do
        touch "itu-r-bo-600-1.yaml", "report-itu-r-bt-2020-1.yaml",
              "itu-t-a-1-10-2000.yaml"
        described_class.harvest

        expect(Dir["data/*.yaml"].map { |f| File.basename f })
          .to contain_exactly("itu-r-bo-600-1.yaml", "report-itu-r-bt-2020-1.yaml")
      end
    end

    # A full run re-fetches every ITU-R record, and the harvest indexes what it
    # writes, so re-deriving the rows from disk would only re-add rows the index
    # already holds.
    it "does not re-derive ITU-R rows from disk on a full run" do
      ENV.delete "RELATON_ITU_MODE"
      in_tmp_repo do
        touch "itu-r-bo-600-1.yaml"
        described_class.harvest

        expect(fetcher).not_to have_received(:index_files)
      end
    end

    # ...but a top-up skips the editions already on disk, and a skipped edition
    # is dropped before it is ever parsed (DataCrawlerR#harvest rejects it from
    # the level-2 rows), so it never reaches the index this run rebuilds from
    # scratch. Without this, a quiet top-up day would publish an index holding
    # only the handful of new ITU-R editions — every other row gone, with no
    # guard firing, because the data files themselves are untouched.
    it "re-derives the rows of the records a top-up will skip" do
      ENV["RELATON_ITU_MODE"] = "top_up"
      in_tmp_repo do
        touch "itu-r-bo-600-1.yaml"
        described_class.harvest

        expect(fetcher).to have_received(:index_files).with(ItuCrawler::DATA_R_GLOB)
      end
    end
  end

  describe ".classify_r" do
    it "splits the ITU-R families by filename" do
      expect(described_class.classify_r(%w[
                                          data/itu-r-bo-600-1.yaml
                                          data/report-itu-r-bt-2020-1.yaml
                                          data/itu-r-r-1-1993.yaml
                                          data/itu-r-202-2-2002.yaml
                                          data/itu-r-43-hdb-2013.yaml
                                        ]))
        .to eq(recommendation: 1, report: 1, resolution: 1, question: 2)
    end
  end

  describe ".guard_itur_harvest" do
    it "passes when the corpus is intact" do
      in_tmp_repo do
        commit "itu-r-bo-600-1.yaml", "report-itu-r-bt-2020-1.yaml"
        expect { described_class.guard_itur_harvest }.not_to raise_error
      end
    end

    # The masking case the per-family split exists for: ITU throttles /pub and
    # /rec differently, so Reports can be lost whole while Recommendations look
    # healthy. Counted as one ITU-R bucket this run would publish the hole.
    it "aborts when one family collapses while the other is healthy" do
      in_tmp_repo do
        commit(*Array.new(100) { |i| "itu-r-bo-#{i}.yaml" },
               *Array.new(20) { |i| "report-itu-r-bo-#{i}.yaml" })
        FileUtils.rm_f Dir["data/report-itu-r-*.yaml"]

        expect { described_class.guard_itur_harvest }
          .to raise_error(SystemExit).and output(/report/).to_stderr
      end
    end

    # The first full run is exactly this: ~1,001 records leave the recommendation
    # bucket for a report bucket that was empty. Both halves of that must pass —
    # a family with nothing committed has nothing to protect, and the
    # recommendation bucket's drop is well inside the 50% threshold. Counts are
    # this repo's own, measured 2026-08-20 (4,332/213/789/0 committed) against the
    # hand-off's measured post-crawl shape.
    it "does not fire on the Report-identity rebuild it exists to protect" do
      in_tmp_repo do
        commit(*Array.new(4332) { |i| "itu-r-bo-#{i}.yaml" },
               *Array.new(213) { |i| "itu-r-r-#{i}.yaml" },
               *Array.new(789) { |i| "itu-r-#{i}-2002.yaml" })
        FileUtils.rm_f Dir["data/itu-r-bo-*.yaml"].sample(4332 - 3331)
        touch(*Array.new(1001) { |i| "report-itu-r-bo-#{i}.yaml" })

        expect { described_class.guard_itur_harvest }.not_to raise_error
      end
    end
  end
end
