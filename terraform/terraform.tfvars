# This file is committed on purpose. A bucket name is configuration, not a
# secret — and CI reads its configuration out of the repo, so anything the
# pipeline needs to know has to be written down here rather than typed into
# your shell. Contrast that with your AWS keys in Part C: those also have to
# reach the runner, but must never be in a file like this one.

# Pick something globally unique, e.g. "lab09-<your-pennkey>-website".
bucket_name = "lab09-flin0-website"
