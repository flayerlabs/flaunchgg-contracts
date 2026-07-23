#!/bin/bash
set -e
forge build
rm -rf docs/autogen
# generate docs
forge doc -b -o docs/autogen

# Unstage all docs where only the commit hash changed
# Get a list of all unstaged files in the directory
files=$(git diff --name-only -- 'docs/autogen/*')

# Loop over each file
for file in $files; do
    # Check if the file exists
    if [[ -f $file ]]; then
        # Get the diff for the file, strip metadata and only keep lines that start with - or +
        diff=$(git diff $file | sed '/^diff --git/d; /^index /d; /^--- /d; /^\+\+\+ /d; /^@@ /d' | grep '^[+-]')
        
        # Filter lines that start with -[Git Source] or +[Git Source]
        filtered_diff=$(echo "$diff" | grep '^\-\[Git Source\]\|^\+\[Git Source\]' || true)

        # Compare the original diff with the filtered diff
        if [[ "$diff" == "$filtered_diff" ]]; then
            # If they are equal, discard the changes for the file
            git reset HEAD $file
            git checkout -- $file
        fi
    fi
done