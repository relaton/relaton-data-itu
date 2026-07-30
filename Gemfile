# frozen_string_literal: true

source "https://rubygems.org"

# index-v2 is a pubid-structured index (rows carry `_type: pubid:itu:*`). It must
# be produced by the SAME relaton/pubid the released Relaton::Itu flavor consumes:
#   - relaton monorepo (main) — the ITU index-v2 flavor.
#   - pubid (main) — ITU Question/Handbook identifier parsing, the flat `to_hash`
#     the index rows use, and the `#number` delegation that lets Relaton::Index
#     sort the index by document number.
#
# NOTE: the ITU-T harvest path in crawler.rb (`DataFetcher.fetch("itu-t")`) needs
# the ITU-T producer (issue relaton-itu#80, branch feat/itu-t-index-harvester)
# merged to relaton `main`. Until then only the ITU-R index-derivation step runs;
# the pins below already satisfy that (they built the migrated ITU-R index-v2).
gem "relaton", git: "https://github.com/relaton/relaton.git", branch: "main"
gem "pubid", git: "https://github.com/metanorma/pubid.git", branch: "main"

# index generation + verification
gem "rspec", "~> 3.0"
gem "rubyzip", "~> 2.3"
