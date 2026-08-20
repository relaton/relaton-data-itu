# frozen_string_literal: true

# Combined ITU dataset crawler — builds one `pubid:itu` index-v2 for BOTH sectors.
#
# Both sectors share a single flat data/ folder, distinguished by filename prefix
# (relaton-cli's `relaton index --flavor itu` scans <repo>/data recursively):
#   data/itu-r-*, data/report-itu-r-*
#            ITU-R Recommendations, Reports, Questions, Resolutions and Handbooks,
#            crawled from the /pub + /rec pages ITU still renders server-side
#            (relaton #112) after it decommissioned the RunSearch bulk-enumeration
#            endpoint the original ITU-R crawler paged through (relaton#75). A
#            Report's docid leads with "Report " (relaton #110), which is why the
#            sector needs two prefixes.
#   data/itu-t-*  ITU-T Recommendations (+ supplements/amendments/corrigenda).
#            Harvested from the searchRecs index (issue relaton-itu#80) and WIPED
#            (by the data/itu-t-* glob) + recreated on every run.
#
# Each run rebuilds index-v2 from scratch out of what the two harvests write, so
# stale rows never linger. Both sectors serialize to the same `_type: pubid:itu:*`
# shape, so one index holds them together.
#
# Both passes are driven off a single Relaton::Itu::DataFetcher, so the identifier
# guard, the index and the unparseable-id report are shared rather than duplicated
# here — see #harvest.
#
# ITU-R has two modes, selected by RELATON_ITU_MODE and read by relaton itself
# (DataFetcher.mode), because a full crawl is ~7k requests and ~4 h:
#   full (default)  wipe the ITU-R half and re-derive every record from ITU, which
#                   makes ITU its sole author — the point of crawling it at all.
#   top_up          enumerate the same documents but deep-fetch only the editions
#                   the dataset lacks (~1.4 h). It decides that with File.exist?,
#                   so it must NOT wipe — see #harvest.
# The FIRST run against a pre-#110 dataset must be full: a top_up would add every
# Report a second time under its new `Report …` name.
#
# RELATON_ITU_DELAY (default 1.0) is the politeness pause. Lower it at your peril:
# at 0.4 s a corpus run lost 4 Recommendation series to HTTP 503 and every Report
# series to a soft block. ITU throttles the two path families differently — /rec
# answers 503, /pub a 302 to notfound.aspx that replays as an empty page — and
# relaton retries both (3×, linear backoff) before raising, so a throttled series
# fails loudly rather than publishing nothing.
#
# ITU-T is the other expensive half: ~16k records × ~4 www.itu.int requests for the
# enrichment that makes a harvested record match a live lookup, spread over a
# worker pool (RELATON_ITU_CONCURRENCY, default 8) for ~2 h. Both sectors in one
# process is therefore ~6 h on a full run — at GitHub Actions' per-job cap, so a
# scheduled full crawl wants its own job.

require "fileutils"
require "time"
require "relaton/itu/data_fetcher" # pulls in Relaton::Index + ::Pubid::Itu
require "relaton/index"
require "pubid"
require "zip"

module ItuCrawler
  module_function

  INDEX_YAML = "index-v2.yaml"
  INDEX_ZIP = "index-v2.zip"
  # Both sectors live in one flat data/ folder, split only by filename prefix, so
  # `relaton index --flavor itu` (which scans <repo>/data) sees them. The globs let
  # the crawler re-derive / wipe one sector without touching the other.
  DATA = "data"
  # Both ITU-R spellings. A Report's docid leads with "Report " (relaton #110),
  # so `Report ITU-R BT.2020-1` sanitizes to data/report-itu-r-bt-2020-1.yaml —
  # outside a data/itu-r-* glob. Left as one glob it would miss every Report
  # twice over: the full-run wipe would leave ~1,000 stale Report files behind,
  # and a top-up's `index_files` would drop their rows while `git add -A data`
  # still stages the files — publishing a corpus and an index that disagree, with
  # no guard firing.
  DATA_R_GLOB = "data/{itu-r,report-itu-r}-*.yaml"
  DATA_T_GLOB = "data/itu-t-*.yaml"

  # Rebuild index-v2 from scratch and refresh data/ from ITU.
  #
  # Both sectors run off ONE DataFetcher, which is what keeps them consistent:
  # every id goes through the same pubid guard (parse + lossless round-trip,
  # matching what Relaton::Index's own loader will accept) into the same index.
  #
  # The two harvests are called directly rather than through DataFetcher#fetch,
  # which is harvest + index.save + report_errors: called twice it would save the
  # index twice and report twice, and since report_errors comments on the shared
  # "Error fetching documents" GitHub issue (when GITHUB_REPOSITORY and
  # GITHUB_TOKEN are set), the second comment would repeat the first's ITU-R ids.
  # One save and one report at the end also means an id that cannot be indexed is
  # *named* once, for the whole run, rather than silently dropped.
  def harvest
    FileUtils.rm_f INDEX_YAML         # rebuild the index from scratch
    FileUtils.rm_f Dir[DATA_T_GLOB]   # ITU-T comes from upstream on every run
    FileUtils.rm_f Dir[DATA_R_GLOB] if full? # so does ITU-R, unless topping up
    FileUtils.mkdir_p DATA

    started = Time.now
    warn "crawler: started at #{started.utc.iso8601}"
    fetcher = Relaton::Itu::DataFetcher.new(DATA, "yaml")
    # A top-up skips every edition already on disk, and DataCrawlerR#harvest
    # rejects a skipped edition from its level-2 rows — so it is never parsed,
    # never merged, and never lands in the index this run rebuilds from scratch.
    # Re-derive those rows from the files first, or a quiet top-up day publishes
    # an index holding only the new editions. A full run needs none of this: it
    # wiped the files and re-fetches every one of them.
    fetcher.index_files DATA_R_GLOB unless full?
    fetcher.fetch_publications        # ITU-R: crawl /pub + /rec
    fetcher.fetch_recommendations     # ITU-T: harvest via searchRecs
    fetcher.index.save
    fetcher.report_errors
    warn "crawler: done in #{(Time.now - started).round} sec."
  end

  # Whether this run re-derives the whole ITU-R half or only tops it up. Read from
  # relaton's own RELATON_ITU_MODE reader, so the wipe above and the mode the
  # harvest actually runs in cannot disagree — a top_up against a wiped data/ would
  # find every edition missing and pay for the full crawl anyway.
  def full?
    Relaton::Itu::DataFetcher.mode == :full
  end

  # Guard against silently republishing a truncated index. The searchRecs
  # producer returns `json["Data"] || []`, so any ITU API drift that still yields
  # HTTP 200 + parseable JSON without a populated "Data" key harvests **zero**
  # rows and does not raise — `index.save` would then persist ITU-R-only rows and
  # `git add -A data` would stage the deletion of every published ITU-T file,
  # committing a full ITU-T wipe on a "green" run. Refuse to proceed when the
  # harvest collapses (empty, or a >50% drop) relative to what is already
  # committed. A legitimately-empty data/itu-t-* — the dormant state before the
  # producer merges (0 committed, 0 harvested) — is allowed through.
  def guard_itut_harvest
    had = committed_data_t_count
    now = Dir[DATA_T_GLOB].size
    return if had.zero?          # nothing published to protect yet
    return unless now * 2 < had  # allow normal churn; block a collapse

    abort "ITU-T harvest collapsed: #{now} data/itu-t-* files vs #{had} committed. " \
          "Refusing to republish a truncated index (likely an empty searchRecs " \
          "response). Investigate before re-running."
  end

  # Guard the ITU-R half the same way, but **per family**, because the two
  # families fail independently: ITU throttles by path root (503 on /rec, a 302
  # to notfound.aspx on /pub), and DataFetcher#harvest_family rescues per series
  # and per family and only logs — so a WAF block yields a partial corpus on an
  # otherwise green run. A healthy 3,300-record Recommendation crawl would mask a
  # Reports crawl that lost every series if the two were counted together.
  #
  # Under the full-mode wipe this is the only thing between a throttled crawl and
  # a published hole — and the relaton consumer reads this repo's main at runtime,
  # so the hole would be a live lookup failure, not just a thin dataset.
  def guard_itur_harvest
    now = classify_r(Dir[DATA_R_GLOB])
    had = classify_r(committed_files("data/itu-r-*.yaml") +
                     committed_files("data/report-itu-r-*.yaml"))

    had.each do |family, before|
      after = now[family].to_i
      next if before.zero?         # nothing published to protect yet
      next if after * 2 >= before  # allow normal churn; block a collapse

      abort "ITU-R harvest collapsed: #{after} #{family} files vs #{before} committed. " \
            "Likely a WAF block (503 on /rec, a 302 to notfound.aspx on /pub), or a family " \
            "whose series was skipped after exhausting its retries — grep the log for " \
            "'skipped:'. Investigate before re-running."
    end
  end

  # Which ITU-R family a data file belongs to, by filename.
  #
  # Counting the ITU-R half as one bucket does not work: a run that loses one
  # family still keeps ~96% of the files and sails through any sane threshold.
  # That is not hypothetical — a single Net::ReadTimeout on one Resolution page
  # cost all 213 Resolutions in a measured crawl, and the run still exited 0 with
  # a full-looking index, because DataFetcher#harvest_family rescues per family
  # and DataMergeR writes only at series end.
  #
  # Filename is the only cheap discriminator. The index cannot help: an ITU-R
  # Resolution serializes as `pubid:itu:recommendation` with `series: R`, so
  # `_type` does not separate the families either.
  #
  # Handbooks land in :question (`itu-r-43-hdb-2013.yaml` leads with a digit).
  # That is harmless: ~63 edition-keyed handbook files against ~789 Questions is
  # too small a share to move the threshold either way.
  def classify_r(files)
    files.each_with_object(Hash.new(0)) do |f, h|
      base = File.basename(f)
      h[case base
         when /\Areport-itu-r-/ then :report       # Report ITU-R … (relaton #110)
         when /\Aitu-r-r-/ then :resolution        # series "R" is Resolutions only
         when /\Aitu-r-\d/ then :question          # + the preserved handbooks
         else :recommendation
         end] += 1
    end
  end

  # Count of ITU-T data files already committed (tracked at HEAD). Zero in a fresh
  # checkout with no commits, or while the ITU-T half is still dormant.
  def committed_data_t_count
    committed_count DATA_T_GLOB
  end

  # Files matching `glob` that are tracked at HEAD. Single-quoted so git (not the
  # shell) expands the pathspec — git's `*` matches across `/`, so it selects
  # exactly the committed files. Pass a plain `*` glob, not a brace one: git
  # pathspecs are fnmatch patterns and do not expand `{a,b}`.
  def committed_files(glob)
    `git ls-files -- '#{glob}'`.each_line.map(&:chomp)
  end

  def committed_count(glob)
    committed_files(glob).size
  end

  # Guard against republishing a metadata-thin corpus. ITU-T enrichment (abstract,
  # ISO co-id, status, edition, contributors, relations) costs ~4 www.itu.int
  # requests per record and is best-effort: DataParserT#enrichment rescues any
  # failure and returns the thin searchRecs shape instead, so a WAF block part-way
  # through degrades records silently while the crawl still "succeeds" with the
  # full file count — invisible to guard_itut_harvest, which counts files.
  # The ITU publisher contributor is added unconditionally whenever enrichment
  # succeeds, so `contributor:` is exactly the marker for "this record kept its
  # enrichment".
  def guard_enrichment
    files = Dir[DATA_T_GLOB]
    return if files.empty?

    enriched = files.count { |f| File.foreach(f).any? { |l| l.start_with?("contributor:") } }
    return if enriched * 10 >= files.size * 9 # allow a 10% tail of genuinely failed records

    abort "ITU-T enrichment collapsed: only #{enriched}/#{files.size} records carry " \
          "contributors. Likely www.itu.int throttling — investigate before republishing."
  end

  # Rebuild index-v2.zip in process (rubyzip is a relaton/index dependency), so a
  # standalone `ruby crawler.rb` run produces a complete, committable state.
  def write_zip
    FileUtils.rm_f INDEX_ZIP
    Zip::File.open(INDEX_ZIP, create: true) { |zip| zip.add(INDEX_YAML, INDEX_YAML) }
  end

  # Stage the data/ folder + index files. `-A data` captures the ITU-R files, the
  # freshly harvested ITU-T files, and the deletions of any ITU-T files pruned by
  # the data/itu-t-* wipe. (The reusable relaton/support crawler workflow already
  # auto-stages `data/*` + `index*.yaml`; we stage explicitly so a standalone
  # `ruby crawler.rb` run also produces a complete, committable state.)
  def stage
    system("git", "add", "-A", DATA, INDEX_YAML, INDEX_ZIP) ||
      warn("warning: `git add` failed (not a git repo?); files were still written")
  end

  # write_zip runs before the guards so index-v2.yaml (saved by the fetcher) and
  # index-v2.zip can never be left out of sync by an abort. The guards still block
  # publication: they abort before `stage`, and before the CI workflow's commit.
  def run
    harvest
    write_zip
    guard_itut_harvest
    guard_itur_harvest
    guard_enrichment
    stage
  end
end

ItuCrawler.run if $PROGRAM_NAME == __FILE__
