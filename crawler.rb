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
#   data/itu-t-*  ITU-T Recommendations (+ supplements/amendments/corrigenda),
#            harvested from the searchRecs index (issue relaton-itu#80).
#
# Each run rebuilds index-v2 from scratch, out of what the two harvests write plus
# what #index_files re-derives from disk, so stale rows never linger. Both sectors
# serialize to the same `_type: pubid:itu:*` shape, so one index holds them together.
#
# Both passes are driven off a single Relaton::Itu::DataFetcher, so the identifier
# guard, the index and the unparseable-id report are shared rather than duplicated
# here — see #harvest.
#
# MODE. One knob, RELATON_ITU_MODE, read by relaton itself (DataFetcher.mode) and,
# since relaton #117, honoured by BOTH sectors. This file sets it from ARGV[0] (see
# .apply_mode!), because the reusable relaton/support crawler workflow can pass
# arguments but not environment — which is what lets one workflow file drive two
# different schedules:
#   full (default)  wipe both halves and re-derive every record from ITU, making ITU
#                   their sole author — the point of crawling at all. ~3.5 h (ITU-R
#                   ~2 h, ITU-T ~1.6 h). This is also the only thing that PRUNES: a
#                   top-up only ever adds, so without it a withdrawn edition, or a
#                   record whose primary docid changed upstream, lingers forever.
#   top_up          enumerate the same documents but deep-fetch only what the dataset
#                   lacks: ITU-R per edition (DataFetcher#held?), ITU-T per
#                   recommendation family (#held_t?, grouped because a new edition
#                   changes its siblings' hasEdition relations). Both decide from the
#                   enumeration row alone, with no HTTP — so NEITHER half may be
#                   wiped, see #harvest. ~0.6 h on a quiet day, nearly all of it
#                   ITU-R level-1/level-2 enumeration; the level-3 edition pages it
#                   skips are ~70% of a full ITU-R crawl.
# Because a top-up skips files instead of rewriting them, the index rows of every
# record it skips must come from disk: #harvest calls #index_files for both globs.
# That is the difference between a quiet day publishing ~21k rows and publishing
# forty.
#
# The FIRST run against a pre-#110 dataset must be full — a top_up would add every
# Report a second time under its new `Report …` name, beside the old-named copy.
# .guard_report_seed refuses such a run before it spends the hours.
#
# RELATON_ITU_DELAY (default 1.0) is the politeness contract. Since #117 it is the
# minimum gap between request STARTS, shared by the whole ITU-R worker pool
# (RELATON_ITU_R_CONCURRENCY, default 4), not a sleep before each request: ITU's own
# ~1.1 s latency now counts toward the gap instead of being added on top, so the peak
# rate rises from an accidental ~0.48 to at most 1.0 req/s and the pool can never
# exceed 1/delay however many workers run. Lower it at your peril: at 0.4 s a corpus
# run lost 4 Recommendation series to HTTP 503 and every Report series to a soft
# block. ITU throttles the two path families differently — /rec answers 503, /pub a
# 302 to notfound.aspx that replays as an empty page — and relaton retries both (3×,
# linear backoff) before raising, so a throttled series fails loudly rather than
# publishing nothing; a sustained block becomes one pool-wide cooldown
# (RELATON_ITU_THROTTLE_BASE/_MAX/_GIVEUP, 60/900/5). Exact rollback to the pre-#117
# request profile: RELATON_ITU_R_CONCURRENCY=1 RELATON_ITU_PACE=fixed.
#
# ITU-T is the other half: ~16k records × ~4 www.itu.int requests for the enrichment
# that makes a harvested record match a live lookup, over a worker pool
# (RELATON_ITU_CONCURRENCY, default 8) sharing a per-recommendation detail cache
# (RELATON_ITU_CACHE_ENTRIES, default 512) — ~1.6 h. Both sectors in one process is
# therefore ~3.5 h, inside GitHub Actions' 6 h per-job cap, so the scheduled crawl
# stays ONE job and the schedule differentiates by mode, not by job
# (.github/workflows/crawler.yml).

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

  # Crawl modes accepted on the command line — deliberately the same two spellings
  # RELATON_ITU_MODE takes, so there is one vocabulary rather than a mapping.
  MODES = %w[full top_up].freeze

  # Turn `ruby crawler.rb top_up` into RELATON_ITU_MODE=top_up, before anything
  # reads it.
  #
  # The mode has to reach relaton through the ENVIRONMENT — DataFetcher.mode is its
  # only reader — but must arrive as an ARGUMENT: the reusable relaton/support
  # crawler workflow runs `<fetch-command> <inputs.args> <secrets.args>` and has no
  # env input at all, so a per-cron mode is otherwise unexpressible without forking
  # that workflow. Setting ENV here, before #full? or either harvest reads it, is
  # also what keeps the wipe decision and the harvest mode from disagreeing.
  #
  # An empty argv leaves the environment untouched rather than writing "full" into
  # it: `RELATON_ITU_MODE=top_up ruby crawler.rb` keeps working, and the default
  # stays defined in exactly one place (DataFetcher.mode). An explicit argument wins
  # over an inherited env var — it is the more specific instruction.
  #
  # Anything else aborts rather than being ignored. A typo ("topup", "--top-up")
  # would otherwise silently run the ~3.5 h full crawl six days a week, which is
  # www.itu.int's problem as much as ours. A second argument aborts for the same
  # reason: the workflow appends `secrets.args` to the command line, so an extra
  # word means someone configured something this script does not honour.
  #
  # NOT called at require time, and NOT called from .run. spec/crawler_spec.rb does
  # `require_relative "../crawler"`, so a parse at load — or inside .run, which a
  # spec may call — would read RSPEC's ARGV ("spec/crawler_spec.rb", "-e", …) and
  # abort the suite. The only caller is the `$PROGRAM_NAME == __FILE__` line at the
  # bottom of this file; the argv parameter exists so specs can drive it directly.
  #
  # @param argv [Array<String>] defaults to the process's own ARGV
  # @return [void]
  def apply_mode!(argv = ARGV)
    return if argv.empty?

    mode = argv.first
    unless argv.size == 1 && MODES.include?(mode)
      abort "usage: ruby crawler.rb [#{MODES.join '|'}] (got #{argv.inspect})"
    end

    ENV["RELATON_ITU_MODE"] = mode
  end

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
    # Both halves are wiped on a full run and NEITHER on a top-up. Since relaton
    # #117 the ITU-T harvest honours the mode too, and it decides what to skip with
    # File.exist? (DataFetcher#held_t?) exactly as ITU-R does with #held? — so a
    # wipe here would make every record look missing and turn the cheap daily run
    # back into a full crawl of that sector.
    FileUtils.rm_f Dir[DATA_T_GLOB] if full?
    FileUtils.rm_f Dir[DATA_R_GLOB] if full?
    FileUtils.mkdir_p DATA

    started = Time.now
    warn "crawler: started at #{started.utc.iso8601}"
    fetcher = Relaton::Itu::DataFetcher.new(DATA, "yaml")
    # A top-up skips what is already on disk BEFORE parsing it: DataCrawlerR#harvest
    # drops a skipped ITU-R edition from its level-2 rows, and DataFetcher#top_up_rows
    # drops every row of an ITU-T family holding no new edition. Skipped means never
    # parsed, never merged, never indexed — and this run rebuilds the index from
    # scratch. Re-derive those rows from the files first, or a quiet top-up day
    # publishes an index holding only the day's handful of new editions while ~21k
    # data files sit on disk and `git add -A data` stages nothing that would betray
    # it: every guard below counts FILES, not rows, so none of them fires.
    #
    # It is also what makes a degraded searchRecs response survivable in top-up
    # mode: the rows come from disk, so an empty "Data" key costs new records rather
    # than published ones. Cost is ~21k YAML loads, single-digit minutes against the
    # ~35 min of a quiet top-up. A full run needs none of it: it wiped the files and
    # re-fetches every one of them.
    unless full?
      fetcher.index_files DATA_R_GLOB
      fetcher.index_files DATA_T_GLOB
    end
    fetcher.fetch_publications        # ITU-R: crawl /pub + /rec
    fetcher.fetch_recommendations     # ITU-T: harvest via searchRecs
    fetcher.index.save
    fetcher.report_errors
    warn "crawler: done in #{(Time.now - started).round} sec."
  end

  # Whether this run re-derives the whole corpus or only tops it up. Read from
  # relaton's own RELATON_ITU_MODE reader, so the wipe above and the mode the
  # harvest actually runs in cannot disagree — a top_up against a wiped data/ would
  # find every record missing and pay for the full crawl anyway.
  def full?
    Relaton::Itu::DataFetcher.mode == :full
  end

  # Refuse a top-up onto a pre-#110 dataset.
  #
  # Before relaton #110 a Report was filed under the plain sector name
  # (data/itu-r-bt-2246-0.yaml, docid "ITU-R BT.2246-0"); it is now
  # data/report-itu-r-* with a docid leading "Report ". A top-up decides what to
  # fetch with File.exist? on the NEW name, so against the old corpus every Report
  # looks missing: the run re-fetches all ~1,000 of them and writes them BESIDE
  # their old-named copies. Nothing then removes the old files — only a full run
  # wipes — so the sector doubles, `git add -A data` stages both spellings, and
  # #index_files has already put the stale ones in the index.
  #
  # No other guard catches that. guard_itur_harvest blocks COLLAPSES, and this is
  # growth: report 0 -> ~1,000, recommendation unchanged. That is precisely the
  # shape of the legitimate rebuild it is written to let through.
  #
  # Read off the working tree rather than HEAD, because File.exist? is what the
  # top-up will consult. `itu-r-*` populated with `report-itu-r-*` empty IS the
  # pre-#110 signature; an empty ITU-R half (fresh checkout, first crawl) has
  # nothing to duplicate and is let through — the full run seeds it.
  #
  # KEEP THIS after the seed lands. It looks inert once report-itu-r-* exists, but
  # it is what protects a top-up run against any older checkout of this repo, and
  # the state it rejects is invisible to every other guard here.
  def guard_report_seed
    return if full?
    return if Dir["data/itu-r-*.yaml"].empty?
    return unless Dir["data/report-itu-r-*.yaml"].empty?

    abort "top-up refused: #{Dir['data/itu-r-*.yaml'].size} data/itu-r-* files and no " \
          "data/report-itu-r-* — a pre-relaton#110 dataset, where Reports are still filed " \
          "under their old names. A top-up would re-fetch every Report under its new " \
          "`Report …` name and write it beside the old-named copy, doubling the sector, " \
          "with no guard firing. Seed the dataset with one full crawl " \
          "(`ruby crawler.rb full`, ~3.5 h) — only a full run retires the old names."
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
  #
  # Structurally inert in top-up mode, where nothing is wiped and the file count
  # only ever rises. The full run is where it is load-bearing.
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
  # so the hole would be a live lookup failure, not just a thin dataset. It is also
  # what catches a concurrent ITU-R crawl (relaton #117) meeting a WAF block, which
  # is why its per-family granularity must not be relaxed: relaton deliberately
  # keeps that parallelism *inside* a series so this still means what it meant.
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
  #
  # Weak in top-up mode BY DESIGN: it counts across all data/itu-t-*, which on a
  # top-up are overwhelmingly untouched files from the last full run, so a top-up
  # that degrades its handful of new records still passes at 9/10. The weekly full
  # run is the real check. Scoping the count by mtime was considered and rejected —
  # it would be flaky, and it would fire on days that harvested nothing.
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
  # freshly harvested ITU-T files, and the deletions of any file pruned by a
  # full run's wipe. (The reusable relaton/support crawler workflow already
  # auto-stages `data/*` + `index*.yaml`; we stage explicitly so a standalone
  # `ruby crawler.rb` run also produces a complete, committable state.)
  def stage
    system("git", "add", "-A", DATA, INDEX_YAML, INDEX_ZIP) ||
      warn("warning: `git add` failed (not a git repo?); files were still written")
  end

  # guard_report_seed runs FIRST, before the harvest: it is a precondition on the
  # dataset the harvest READS, not a verdict on what it produced, and the state it
  # rejects takes ~3.5 h to discover any other way. It could not be moved after the
  # harvest even if time were free — by then the duplicate Reports are written and
  # indexed, and the collapse guards would wave the run through.
  #
  # The rest keep their order. write_zip runs before the guards so index-v2.yaml
  # (saved by the fetcher) and index-v2.zip can never be left out of sync by an
  # abort. The guards still block publication: they abort before `stage`, and a
  # non-zero exit fails the workflow's fetch step before its commit.
  def run
    guard_report_seed
    harvest
    write_zip
    guard_itut_harvest
    guard_itur_harvest
    guard_enrichment
    stage
  end
end

if $PROGRAM_NAME == __FILE__
  ItuCrawler.apply_mode!   # ARGV -> RELATON_ITU_MODE, before anything reads it
  ItuCrawler.run
end
