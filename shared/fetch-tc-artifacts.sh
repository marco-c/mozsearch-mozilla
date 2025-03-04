#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

if [ $# -ne 2 ]; then
    echo "Usage: $0 <revision-tree> <hg-rev>"
    echo " e.g.: $0 mozilla-central 588208caeaf863f2207792eeb1bd97e6c8fceed4"
    exit 1
fi

REVISION_TREE=$1
INDEXED_HG_REV=$2

# Allow caller to override what we use to download, but
# have a sane default
CURL=${CURL:-"curl -SsfL --compressed"}

# Rewrite REVISION to be a specific revision in case the "latest" pointer changes while
# we're in the midst of downloading stuff. Using a specific revision id is safer.
REVISION="${REVISION_TREE}.revision.${INDEXED_HG_REV}"

# Download the bugzilla components file and the artifacts from each platform that
# we're indexing. But do them in parallel by emitting all the curl commands into
# a file and then feeding it to GNU parallel.
echo "${CURL} https://index.taskcluster.net/v1/task/gecko.v2.$REVISION.source.source-bugzilla-info/artifacts/public/components-normalized.json > bugzilla-components.json" > downloads.lst
for PLATFORM in linux64 macosx64 win64 android-armv7; do
    # First check that the the searchfox job exists for the platform and revision we want. Otherwise emit a warning and skip it. This
    # file is small so it's cheap to download and spew to stdout as a check that the analysis data for the platform exists.
    ${CURL} https://index.taskcluster.net/v1/task/gecko.v2.$REVISION.firefox.$PLATFORM-searchfox-debug/artifacts/public/build/target.json ||
    (   echo "WARNING: Unable to find analysis for $PLATFORM for hg rev $INDEXED_HG_REV; skipping analysis merge step for this platform." &&
        continue
    )

    TC_PREFIX="https://index.taskcluster.net/v1/task/gecko.v2.${REVISION}.firefox.${PLATFORM}-searchfox-debug/artifacts/public/build"
    # C++ analysis
    echo "${CURL} ${TC_PREFIX}/target.mozsearch-index.zip > ${PLATFORM}.mozsearch-index.zip" >> downloads.lst
    # Rust save-analysis files
    echo "${CURL} ${TC_PREFIX}/target.mozsearch-rust.zip > ${PLATFORM}.mozsearch-rust.zip" >> downloads.lst
    # Rust stdlib src and analysis data
    echo "${CURL} ${TC_PREFIX}/target.mozsearch-rust-stdlib.zip > ${PLATFORM}.mozsearch-rust-stdlib.zip" >> downloads.lst
    # Generated sources tarballs
    echo "${CURL} ${TC_PREFIX}/target.generated-files.tar.gz > ${PLATFORM}.generated-files.tar.gz" >> downloads.lst
    # Manifest for dist/include entries
    echo "${CURL} ${TC_PREFIX}/target.mozsearch-distinclude.map > ${PLATFORM}.distinclude.map" >> downloads.lst
done # end PLATFORM loop

# Do the downloads
parallel --halt now,fail=1 < downloads.lst

# Clean out any leftover artifacts if we're running using KEEP_WORKING=1
rm -rf analysis && mkdir -p analysis
rm -rf objdir && mkdir -p objdir
