# frozen_string_literal: true

# Unit guard for crawler.rb, the producer side of this dataset. index_v2_spec.rb
# checks what was published; this checks the code that decides what gets
# published — which of the two sectors is wiped before a harvest, whose rows are
# re-derived from disk, and whether a collapsed crawl is allowed to reach
# `git add`.
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

  # The mode has to reach relaton as an environment variable — DataFetcher.mode is
  # its only reader — but has to ARRIVE as a command-line argument, because the
  # reusable relaton/support crawler workflow passes args and offers no env input.
  # This is the join between the two.
  describe ".apply_mode!" do
    # No argument means "whatever the environment says", so
    # `RELATON_ITU_MODE=top_up ruby crawler.rb` keeps working and the default lives
    # in exactly one place (DataFetcher.mode), not in two that can drift.
    it "leaves the environment alone when no mode is given" do
      ENV["RELATON_ITU_MODE"] = "top_up"
      described_class.apply_mode! []
      expect(described_class.full?).to be false
    end

    it "sets the mode from ARGV[0]" do
      ENV.delete "RELATON_ITU_MODE"
      described_class.apply_mode! ["top_up"]
      expect(described_class.full?).to be false
    end

    # An explicit argument is the more specific instruction, so it wins over an
    # inherited env var — the weekly full run must not be turned into a top-up by a
    # stray variable in the runner's environment.
    it "lets an explicit `full` override an inherited top_up" do
      ENV["RELATON_ITU_MODE"] = "top_up"
      described_class.apply_mode! ["full"]
      expect(described_class.full?).to be true
    end

    # A typo must not degrade to the default: "topup" silently running the ~3.5 h
    # full crawl six days a week is www.itu.int's problem as much as ours.
    it "aborts on an unknown mode instead of falling back to a full crawl" do
      expect { described_class.apply_mode! ["topup"] }
        .to raise_error(SystemExit).and output(/usage/).to_stderr
    end

    # The workflow appends `secrets.args` to the command line, so a second word
    # means something is configured that this script does not honour.
    it "aborts on extra arguments" do
      expect { described_class.apply_mode! %w[top_up --force] }
        .to raise_error(SystemExit).and output(/usage/).to_stderr
    end
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

    # A top-up decides what to skip with File.exist? — DataFetcher#held? per ITU-R
    # edition, #held_t? per ITU-T recommendation family (relaton #117). Wiping
    # either half would make everything look missing and turn the cheap daily run
    # back into a full crawl of that sector.
    it "keeps both sectors' records on a top-up" do
      ENV["RELATON_ITU_MODE"] = "top_up"
      in_tmp_repo do
        touch "itu-r-bo-600-1.yaml", "report-itu-r-bt-2020-1.yaml",
              "itu-t-a-1-10-2000.yaml"
        described_class.harvest

        expect(Dir["data/*.yaml"].map { |f| File.basename f })
          .to contain_exactly("itu-r-bo-600-1.yaml", "report-itu-r-bt-2020-1.yaml",
                              "itu-t-a-1-10-2000.yaml")
      end
    end

    # A full run re-fetches every record in both sectors, and the harvest indexes
    # what it writes, so re-deriving rows from disk would only re-add rows the
    # index already holds.
    it "does not re-derive any rows from disk on a full run" do
      ENV.delete "RELATON_ITU_MODE"
      in_tmp_repo do
        touch "itu-r-bo-600-1.yaml", "itu-t-a-1-10-2000.yaml"
        described_class.harvest

        expect(fetcher).not_to have_received(:index_files)
      end
    end

    # ...but a top-up skips the records already on disk, and a skipped record is
    # dropped before it is ever parsed (DataCrawlerR#harvest rejects a skipped
    # ITU-R edition from its level-2 rows), so it never reaches the index this run
    # rebuilds from scratch. Without this, a quiet top-up day would publish an
    # index holding only the handful of new ITU-R editions — every other row gone,
    # with no guard firing, because the data files themselves are untouched.
    it "re-derives the ITU-R rows a top-up will skip" do
      ENV["RELATON_ITU_MODE"] = "top_up"
      in_tmp_repo do
        touch "itu-r-bo-600-1.yaml"
        described_class.harvest

        expect(fetcher).to have_received(:index_files).with(ItuCrawler::DATA_R_GLOB)
      end
    end

    # The same hazard on the ITU-T side since relaton #117: DataFetcher#top_up_rows
    # drops every row of a family with no new edition, so a quiet day harvests a
    # handful of families and would otherwise publish an index of only those —
    # ~16k files on disk, forty rows in the index, and not one guard firing,
    # because they all count files.
    it "re-derives the ITU-T rows a top-up will skip" do
      ENV["RELATON_ITU_MODE"] = "top_up"
      in_tmp_repo do
        touch "itu-t-a-1-10-2000.yaml"
        described_class.harvest

        expect(fetcher).to have_received(:index_files).with(ItuCrawler::DATA_T_GLOB)
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

  describe ".guard_report_seed" do
    # The state this repo was in before the rebuild: thousands of data/itu-r-*,
    # zero data/report-itu-r-*, Reports still filed as itu-r-bt-2246-0.yaml. A
    # top-up here writes every Report a second time under its new name, beside the
    # old copy — growth, so guard_itur_harvest lets it straight through.
    it "aborts a top-up onto a pre-#110 dataset" do
      ENV["RELATON_ITU_MODE"] = "top_up"
      in_tmp_repo do
        touch "itu-r-bo-600-1.yaml", "itu-t-a-1-10-2000.yaml"
        expect { described_class.guard_report_seed }
          .to raise_error(SystemExit).and output(/pre-relaton#110/).to_stderr
      end
    end

    # A full run IS the fix — it wipes the old names — so it must never be blocked
    # by the state it exists to repair.
    it "does not fire on a full run, which is what repairs the dataset" do
      ENV.delete "RELATON_ITU_MODE"
      in_tmp_repo do
        touch "itu-r-bo-600-1.yaml"
        expect { described_class.guard_report_seed }.not_to raise_error
      end
    end

    # Nothing on disk means nothing to duplicate: a fresh checkout, or the very
    # first crawl, must be allowed through whatever mode it runs in.
    it "does not fire when the ITU-R half is empty" do
      ENV["RELATON_ITU_MODE"] = "top_up"
      in_tmp_repo do
        touch "itu-t-a-1-10-2000.yaml"
        expect { described_class.guard_report_seed }.not_to raise_error
      end
    end

    # And it must stand down the moment the rebuild lands, or every subsequent
    # daily run aborts.
    it "does not fire once the Report rebuild has landed" do
      ENV["RELATON_ITU_MODE"] = "top_up"
      in_tmp_repo do
        touch "itu-r-bo-600-1.yaml", "report-itu-r-bt-2020-1.yaml"
        expect { described_class.guard_report_seed }.not_to raise_error
      end
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

  describe ".run" do
    # Ordering, stated as behaviour rather than as a mock expectation: the seed
    # guard is a precondition on what the harvest READS, and the run it rejects
    # costs ~3.5 h to reject any other way. After the harvest it would also be
    # useless — the duplicate Reports are written and indexed by then, and every
    # other guard only blocks collapses.
    it "aborts a bad seed before the harvest, not after hours of crawling" do
      ENV["RELATON_ITU_MODE"] = "top_up"
      in_tmp_repo do
        touch "itu-r-bo-600-1.yaml"
        allow(described_class).to receive(:harvest)

        expect { described_class.run }.to raise_error(SystemExit)
        expect(described_class).not_to have_received(:harvest)
      end
    end
  end
end
