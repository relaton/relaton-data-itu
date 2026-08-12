# frozen_string_literal: true

# Combined ITU dataset crawler — builds one `pubid:itu` index-v2 for BOTH sectors.
#
# Both sectors share a single flat data/ folder, distinguished by filename prefix
# (relaton-cli's `relaton index --flavor itu` scans <repo>/data recursively):
#   data/itu-r-*  ITU-R corpus. Migrated once from relaton-data-itu-r and
#            PRESERVED: ITU killed the bulk-enumeration endpoint that harvested it
#            (the old RunSearch search) and there is no known replacement "list all
#            ITU-R publications" source yet, so it cannot be re-crawled. Left
#            untouched.
#   data/itu-t-*  ITU-T Recommendations (+ supplements/amendments/corrigenda).
#            Harvested from the searchRecs index (issue relaton-itu#80) and WIPED
#            (by the data/itu-t-* glob) + recreated on every run.
#
# Each run rebuilds index-v2 from scratch: re-derive the ITU-R rows from the
# preserved data/itu-r-* files, then merge the fresh ITU-T harvest in. So stale ITU-T rows
# never linger and the ITU-R rows are always present. Both sectors serialize to
# the same `_type: pubid:itu:*` shape, so one index holds them together.
#
# Both passes are driven off a single Relaton::Itu::DataFetcher, so the identifier
# guard, the index and the unparseable-id report are shared rather than duplicated
# here — see #harvest. Add a real ITU-R re-harvest into data/itu-r-* once an
# enumeration source is restored — see the hand-offs
# relaton__relaton__itu-runsearch-fix.md (Part 2) and
# relaton__relaton-itu__itu-t-dataset-migration.md.
#
# The ITU-T half is the expensive part: ~16k records × ~4 www.itu.int requests for
# the enrichment that makes a harvested record match a live lookup. The fetcher
# spreads those over a worker pool (RELATON_ITU_CONCURRENCY, default 8).

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
  DATA_R_GLOB = "data/itu-r-*.yaml"
  DATA_T_GLOB = "data/itu-t-*.yaml"

  # Rebuild index-v2 from scratch and refresh the ITU-T half of data/.
  #
  # Both sectors run off ONE DataFetcher, which is what keeps them consistent:
  # `index_files` re-derives the ITU-R rows from the preserved data/itu-r-*
  # records and `fetch("itu-t")` harvests the ITU-T corpus, both through the same
  # pubid guard (parse + lossless round-trip, matching what Relaton::Index's own
  # loader will accept), into the same index, with one `index.save` and one
  # unparseable-id report at the end — so an id that cannot be indexed is *named*
  # (and raised as the "Error fetching documents" GitHub issue when
  # GITHUB_REPOSITORY and GITHUB_TOKEN are set) rather than silently dropped.
  def harvest
    FileUtils.rm_f INDEX_YAML         # rebuild the index from scratch
    FileUtils.rm_f Dir[DATA_T_GLOB]   # wipe only the ITU-T half; preserve data/itu-r-*
    FileUtils.mkdir_p DATA

    started = Time.now
    warn "crawler: started at #{started.utc.iso8601}"
    fetcher = Relaton::Itu::DataFetcher.new(DATA, "yaml")
    fetcher.index_files DATA_R_GLOB   # ITU-R: re-index the preserved records
    fetcher.fetch "itu-t"             # ITU-T: harvest, then save the index + report
    warn "crawler: done in #{(Time.now - started).round} sec."
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

  # Count of ITU-T data files already committed (tracked at HEAD). Zero in a fresh
  # checkout with no commits, or while the ITU-T half is still dormant. The glob is
  # single-quoted so git (not the shell) expands the pathspec — git's `*` matches
  # across `/`, so it selects exactly the committed data/itu-t-* files.
  def committed_data_t_count
    `git ls-files -- '#{DATA_T_GLOB}'`.each_line.count
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
    guard_enrichment
    stage
  end
end

ItuCrawler.run if $PROGRAM_NAME == __FILE__
