#!/bin/bash

# Delete existing bin directory if it exists
if [ -d "bin" ]; then
    echo "Removing existing bin directory..."
    rm -rf bin
fi

# Create bin directory
echo "Creating bin directory..."
mkdir -p bin

# Make all source scripts executable
echo "Making source scripts executable..."
find src -type f -name "*.sh" -exec chmod +x {} \;

# Find all .sh files in src and create symlinks
echo "Creating symlinks..."
find src -type f -name "*.sh" | while read -r script; do
    # Remove src/ prefix and replace / with -
    # e.g., src/aws/deploy.sh -> aws/deploy.sh -> aws-deploy.sh
    relative_path="${script#src/}"
    symlink_name="bin/${relative_path//\//-}"

    # Get absolute path for the symlink source
    abs_script_path="$(pwd)/$script"

    echo "  $script -> $symlink_name"
    ln -s "$abs_script_path" "$symlink_name"
done

echo "Done! Created $(find bin -type l | wc -l) symlinks in bin/"
