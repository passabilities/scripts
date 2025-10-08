# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a shell script collection repository for infrastructure automation and deployment tasks. Scripts are organized in subdirectories under `src/` with an automated symlink management system.

## Architecture

### Directory Structure and Symlink System

**Source Directory**: `src/`
- Scripts are organized in logical subdirectories (e.g., `src/aws/`, `src/deploy/`, etc.)
- All scripts should be created and edited here

**Binary Directory**: `bin/`
- Contains auto-generated symlinks to scripts in `src/`
- Symlinks use flattened naming: directory separators are replaced with hyphens
- Example: `src/aws/deploy.sh` → `bin/aws-deploy.sh`
- **Never edit files in `bin/` directly** - they are symlinks regenerated automatically

**Symlink Management**: `setup-bin.sh`
- Top-level utility script that regenerates all symlinks in `bin/`
- Automatically makes all source scripts executable (`chmod +x`)
- Creates symlinks with absolute paths
- Run manually with: `./setup-bin.sh`

**Git Integration**: Pre-commit hook
- Automatically runs `setup-bin.sh` before each commit
- Stages any changes to `bin/` directory
- Ensures symlinks stay synchronized with source scripts
- Located at: `.git/hooks/pre-commit`

### Why This Architecture?

Shell scripts in PATH directories must be directly accessible (subdirectories are not searched). This architecture solves that by:
1. Keeping scripts organized in logical subdirectories under `src/`
2. Creating flat symlinks in `bin/` for PATH accessibility
3. Automating synchronization via git hooks

## Working with Scripts

### Adding New Scripts

1. Create your script in the appropriate subdirectory under `src/`
   ```bash
   touch src/category/my-script.sh
   vim src/category/my-script.sh
   ```

2. The script will automatically become executable and get a symlink when you commit:
   - Pre-commit hook runs `setup-bin.sh`
   - Creates symlink: `bin/category-my-script.sh`

3. Or manually regenerate symlinks immediately:
   ```bash
   ./setup-bin.sh
   ```

### Modifying Existing Scripts

1. **Always edit scripts in `src/` directory**, not in `bin/`
2. Symlinks in `bin/` are automatically updated on commit or when running `setup-bin.sh`
3. Changes are tracked via git in `src/` directory only

### Deleting Scripts

1. Delete the script from `src/`
2. Run `./setup-bin.sh` or commit (pre-commit hook will clean up)
3. The corresponding symlink in `bin/` is automatically removed

### Running Scripts

If `bin/` is in your PATH:
```bash
# Run by flattened name
category-my-script.sh
```

Otherwise:
```bash
# Run from bin directory
./bin/category-my-script.sh

# Or run source directly
./src/category/my-script.sh
```

## Development Workflow

### Standard Workflow
```bash
# 1. Create or edit scripts in src/
vim src/category/new-script.sh

# 2. Test the script
./src/category/new-script.sh

# 3. Commit changes
git add src/category/new-script.sh
git commit -m "Add new script"
# Pre-commit hook automatically updates bin/

# 4. Push changes
git push
```

### Manual Symlink Regeneration
```bash
# Regenerate all symlinks (useful during development)
./setup-bin.sh

# Output shows all created symlinks:
#   src/category/script.sh -> bin/category-script.sh
#   ...
#   Done! Created N symlinks in bin/
```

## Git Configuration

### Always Use SSH for Git Operations
Per repository configuration, always use SSH URLs for git remotes (not HTTPS).

### Pre-commit Hook Behavior
The pre-commit hook (`.git/hooks/pre-commit`):
1. Runs `./setup-bin.sh` to regenerate symlinks
2. Checks for changes in `bin/` directory
3. Automatically stages `bin/` changes if detected
4. Allows commit to proceed

This ensures `bin/` always stays synchronized with `src/` in version control.

## Script Organization Guidelines

### Directory Structure Recommendations
- Use descriptive subdirectory names under `src/` (e.g., `aws/`, `docker/`, `deploy/`)
- Group related scripts together in the same subdirectory
- Keep script names clear and action-oriented (e.g., `setup.sh`, `deploy.sh`)

### Script Naming
- Use lowercase with hyphens for multi-word names
- Include `.sh` extension
- Be descriptive but concise
- Remember: `src/category/action-name.sh` becomes `bin/category-action-name.sh`

### Shebang and Permissions
- Always start scripts with `#!/bin/bash` (or appropriate shell)
- Don't manually set execute permissions - `setup-bin.sh` handles this
- Scripts are automatically made executable during symlink generation

## File Tracking in Git

### Tracked Files
- All scripts in `src/` and subdirectories
- `setup-bin.sh` utility script
- `bin/` directory and all symlinks (auto-maintained by pre-commit hook)

### Ignored Files
- `.idea/` - IntelliJ project files
- `*.iml` - IntelliJ module files
- `.DS_Store` and other macOS system files
- See `.gitignore` for complete list

## Repository Maintenance

### When Adding New Script Categories
1. Create new subdirectory under `src/`: `mkdir -p src/new-category`
2. Add scripts to the new directory
3. Run `./setup-bin.sh` or commit to generate symlinks
4. All scripts in new directory get flattened to `bin/new-category-*.sh`

### Verifying Symlink Integrity
```bash
# Check all symlinks are valid
find bin/ -type l -exec test ! -e {} \; -print

# If output is empty, all symlinks are valid
# If output shows files, those symlinks are broken
```

### Regenerating Everything
```bash
# Clean rebuild of all symlinks
./setup-bin.sh
```

This removes and recreates the entire `bin/` directory, ensuring clean state.
