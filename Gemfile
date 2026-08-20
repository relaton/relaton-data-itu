# frozen_string_literal: true

source "https://rubygems.org"

# index-v2 is a pubid-structured index (rows carry `_type: pubid:itu:*`). It must
# be produced by the SAME relaton/pubid the released Relaton::Itu flavor consumes:
#   - relaton monorepo (main) — the ITU index-v2 flavor.
#   - pubid (main) — ITU Question/Handbook identifier parsing, the flat `to_hash`
#     the index rows use, and the `#number` delegation that lets Relaton::Index
#     sort the index by document number.
#
# NOTE: crawler.rb now harvests BOTH sectors from upstream, so relaton `main` must
# carry the ITU-T producer (relaton-itu#80) and the ITU-R harvester + Report
# identity (relaton#112, #110); pubid `main` must carry the ITU Question/Handbook
# and dashed-series parsing the index rows depend on (#320/#321/#325/#327). There
# is no Gemfile.lock in this repo (it is gitignored), so every run resolves both
# branches afresh — which is the point, but it also means a producer-side
# regression reaches a crawl without a version bump here.
gem "relaton", git: "https://github.com/relaton/relaton.git", branch: "main"
gem "pubid", git: "https://github.com/metanorma/pubid.git", branch: "main"

# index generation + verification
gem "rspec", "~> 3.0"
gem "rubyzip", "~> 2.3"
