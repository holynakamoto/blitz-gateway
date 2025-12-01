#!/bin/bash
set -euo pipefail

# Verify workflows directory exists
if [[ ! -d .github/workflows ]]; then
  echo "Error: .github/workflows directory not found"
  exit 1
fi

echo "Checking GitHub Action versions..."
echo ""

# Track if we found any errors
errors_found=0

# Process each workflow file
for workflow_file in .github/workflows/*.yml .github/workflows/*.yaml; do
  # Skip if no files match the pattern
  [[ ! -f "$workflow_file" ]] && continue

  line_num=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_num++)) || true

    # Skip comments
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    # Check if line contains "uses:"
    if [[ "$line" =~ uses:[[:space:]]*(.+) ]]; then
      # Extract the action string (everything after "uses:")
      action="${BASH_REMATCH[1]}"
      # Trim leading/trailing whitespace
      action=$(echo "$action" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

      # Skip local uses (starting with ./)
      if [[ "$action" =~ ^\./ ]]; then
        continue
      fi

      # Check if action contains '@'
      if [[ ! "$action" =~ @ ]]; then
        echo "❌ ERROR: Invalid action format in $workflow_file:$line_num"
        echo "   Missing '@' separator: $action"
        errors_found=1
        continue
      fi

      # Extract owner/repo and version
      owner_repo="${action%%@*}"
      version="${action##*@}"

      # Trim whitespace from both parts
      owner_repo=$(echo "$owner_repo" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      version=$(echo "$version" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

      # Validate owner_repo is non-empty
      if [[ -z "$owner_repo" ]]; then
        echo "❌ ERROR: Invalid action format in $workflow_file:$line_num"
        echo "   Empty owner/repo (left of '@'): $action"
        errors_found=1
        continue
      fi

      # Validate version is non-empty
      if [[ -z "$version" ]]; then
        echo "❌ ERROR: Invalid action format in $workflow_file:$line_num"
        echo "   Empty version (right of '@'): $action"
        errors_found=1
        continue
      fi

      # Validate owner/repo format (should contain at least one '/')
      if [[ ! "$owner_repo" =~ / ]]; then
        echo "❌ ERROR: Invalid action format in $workflow_file:$line_num"
        echo "   Invalid owner/repo format (missing '/'): $owner_repo"
        echo "   Full action: $action"
        errors_found=1
        continue
      fi

      # If we get here, the action is valid
      echo "✅ $owner_repo@$version"
    fi
  done < "$workflow_file"
done

echo ""

# Exit with error if any invalid entries were found
if [[ $errors_found -eq 1 ]]; then
  echo "❌ Validation failed: Found invalid action entries (see errors above)"
  exit 1
fi

echo "✅ All actions appear to be valid versions."
exit 0
