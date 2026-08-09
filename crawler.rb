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
# NOTE: the ITU-T harvest needs the ITU-T producer (issue relaton-itu#80, branch
# feat/itu-t-index-harvester) merged to relaton `main`, which the Gemfile pins.
# On a relaton `main` without it, `DataFetcher.fetch("itu-t")` ignores the source
# argument and attempts the (dead) ITU-R RunSearch endpoint, which fails — but
# the ITU-R index derivation below has already run and saved, so the ITU-R index
# is intact. Add a real ITU-R re-harvest into data/itu-r-* here once an enumeration
# source is restored — see the hand-offs relaton__relaton__itu-runsearch-fix.md
# (Part 2) and relaton__relaton-itu__itu-t-dataset-migration.md.

require "fileutils"
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

  # Parse an ITU docid into a Pubid::Itu identifier, or nil when it can't be
  # parsed or does not round-trip losslessly. This is the identical guard
  # Relaton::Itu::DataFetcher#pubid and the index loader's
  # Relaton::Index::FileIO#id_supported? apply, so an id that would make
  # Relaton::Index reject the whole index is dropped here instead. The pinned
  # pubid models recommendations, handbooks and questions; the guard only skips
  # the residual forms it can't parse (e.g. "ITU-R RR", malformed dashed ids).
  def pubid(id)
    pid = ::Pubid::Itu.parse id
    hash = pid.to_hash
    return nil unless ::Pubid::Itu::Identifier.from_hash(hash).to_hash == hash

    pid
  rescue StandardError
    nil
  end

  # Rebuild index-v2.yaml with the ITU-R rows derived from the preserved data-r/.
  # Mirrors how relaton-data-nist / relaton-data-iec index their static/ folders:
  # parse each file's primary docid into a pubid object (never a raw String, which
  # Relaton::Index can't sort) and add_or_update it. Skipped ids are left
  # unindexed but their data files stay in data/itu-r-* (graceful degradation).
  def rebuild_itur_index
    FileUtils.rm_f INDEX_YAML
    index = Relaton::Index.find_or_create(
      :itu, file: INDEX_YAML, pubid_class: ::Pubid::Itu::Identifier
    )
    added = 0
    skipped = []
    Dir[DATA_R_GLOB].sort.each do |file|
      item = Relaton::Itu::Item.from_yaml(File.read(file, encoding: "UTF-8"))
      id = (item.docidentifier.find(&:primary) || item.docidentifier.first)&.content
      if id && (pid = pubid(id))
        index.add_or_update pid, file
        added += 1
      else
        skipped << (id || file)
      end
    end
    index.save
    warn "index-v2: #{added} ITU-R rows indexed, #{skipped.size} skipped"
    index
  end

  # Harvest the ITU-T corpus into data-t/, merging its rows into index-v2.yaml
  # (DataFetcher#index re-opens the file rebuild_itur_index just wrote and
  # add_or_updates the ITU-T rows into it, then saves).
  def harvest_itut
    FileUtils.rm_f Dir[DATA_T_GLOB] # wipe only the ITU-T half; preserve data/itu-r-*
    FileUtils.mkdir_p DATA
    Relaton::Itu::DataFetcher.fetch("itu-t", output: DATA)
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

  def run
    rebuild_itur_index
    harvest_itut
    guard_itut_harvest
    write_zip
    stage
  end
end

ItuCrawler.run if $PROGRAM_NAME == __FILE__
