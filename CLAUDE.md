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
- **Executable scripts** (meant for users to run): Include `.sh` extension
- **Library scripts** (sourced by other scripts, not meant for direct execution): NO `.sh` extension
  - Example: `src/aws/lib/prompts` (library), `src/aws/configure.sh` (executable)
- Be descriptive but concise
- Remember: `src/category/action-name.sh` becomes `bin/category-action-name.sh`

### Library Scripts Convention
- Library files (scripts that are sourced, not executed) are placed in `src/lib/` (generic, shared across all scripts)
- Library files should NOT have the `.sh` extension
- Library files are sourced using the LIB_DIR pattern for portability (see Symlink-Safe Path Resolution below)
- Available libraries:
  - `src/lib/prompts` - Interactive prompts library (npm-style UI)
  - `src/lib/config-display` - Configuration display utilities

### Symlink-Safe Path Resolution - CRITICAL

**PROBLEM**: When scripts are run via symlinks (e.g., `bin/aws-code-setup.sh` → `src/aws/code/setup.sh`), the simple `dirname "${BASH_SOURCE[0]}"` pattern resolves to the **symlink's directory**, NOT the actual script location. This breaks relative path resolution to libraries and dependencies.

**SOLUTION**: ALWAYS use this pattern at the start of ANY script that sources libraries or uses relative paths:

```bash
# Get the directory where this script is ACTUALLY located (resolve symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$SCRIPT_DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

# Then calculate LIB_DIR based on actual script location
# Example: script at src/aws/code/setup.sh, lib at src/lib/
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/lib"

# Source libraries
source "${LIB_DIR}/prompts"
source "${LIB_DIR}/codedeploy"
```

**Why it works**:
- Loops through the symlink chain using `readlink`
- Uses `cd -P` to resolve physical (not logical) paths
- Handles both absolute and relative symlinks
- Always finds the REAL script location, not the symlink

**When to use**:
- ✅ ANY script that sources other files or libraries
- ✅ ANY script that uses relative paths for file operations
- ✅ ANY script in this repository (since we use symlinks extensively)

**NEVER use the simple pattern for scripts with dependencies**:
```bash
# ❌ WRONG - breaks when run via symlink
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
```

This will cause "No such file or directory" errors when the script is run from `bin/`.

### Running Scripts from Any Directory
All scripts must be designed to run from any directory. Follow these patterns:

**For finding the script's own directory (use symlink-safe pattern from above):**
```bash
# ALWAYS use the symlink-resolving pattern shown in "Symlink-Safe Path Resolution"
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$SCRIPT_DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
```
This gives you the absolute path to the directory containing the ACTUAL script (not symlink).

**For sourcing libraries:**
```bash
# Calculate LIB_DIR relative to actual script location
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/lib"
source "${LIB_DIR}/prompts"
source "${LIB_DIR}/codedeploy"
```

**For relative file paths:**
Always use absolute paths derived from `SCRIPT_DIR`, never use `$(pwd)` or relative paths.

**Good examples:**
```bash
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"  # Relative to script
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"     # Navigate to root
```

**Bad examples:**
```bash
CONFIG_FILE="./config.env"          # Depends on current directory
source ../lib/prompts               # Relative path, breaks if run from elsewhere
```

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

## AWS Infrastructure Scripts

The repository includes comprehensive AWS infrastructure automation scripts organized by function.

### AWS Visualization Tools (`src/aws/vis/`)

Dedicated visualization and monitoring tools for AWS infrastructure:

**status-dashboard.sh** - Real-time infrastructure health monitoring
- Live status monitoring for all AWS resources
- Color-coded health indicators (healthy/warning/critical/unknown)
- Supports VPCs, RDS, ElastiCache, S3, SES, Elastic Beanstalk
- Project-based filtering or "show all" mode
- Visual separation between resources for readability
- Regional filtering for S3 buckets
- Symlink: `bin/aws-vis-status-dashboard.sh`

**discover-resources.sh** - Automated resource discovery
- Scans all AWS resources in a region
- Tag-based project filtering
- JSON output for automation and integration
- Symlink: `bin/aws-vis-discover-resources.sh`

**visualize-infrastructure.sh** (infra.sh) - Infrastructure visualization
- ASCII diagram generation of infrastructure
- Dependency mapping between services
- Export to multiple formats
- Symlink: `bin/aws-vis-infra.sh`

### Running Visualization Scripts

```bash
# Status dashboard with project filter
./bin/aws-vis-status-dashboard.sh

# Discover all resources
./bin/aws-vis-discover-resources.sh

# Visualize infrastructure
./bin/aws-vis-infra.sh
```

All visualization scripts support:
- Interactive configuration prompts
- Project-based filtering
- "Show all resources" mode (ignore project filters)
- Configuration file loading from `aws-config.env`

### AWS CodeDeploy + CodePipeline Automation (`src/aws/code/`)

Complete AWS CodeDeploy and CodePipeline automation for continuous deployment:

**setup.sh** - Unified infrastructure setup (CodeDeploy + CodePipeline)
- **Comprehensive resource validation** - Checks existing resources before creation
  - Queries AWS for existing applications, deployment groups, pipelines, build projects, and IAM roles
  - Displays current vs. desired configuration with visual diff
  - Offers options: Keep existing / Update (when supported) / Delete and recreate
  - Prevents duplicate resource creation and configuration drift
- Creates CodeDeploy application and deployment groups
- Creates CodePipeline for source → build → deploy automation
- Sets up CodeBuild project with buildspec.yml
- Creates IAM service roles and instance profiles
- Configures deployment strategies (OneAtATime, HalfAtATime, AllAtOnce, etc.)
- Supports EC2/On-Premises, Lambda, and ECS platforms
- **GitHub-only integration** via CodeStar connections (CodeCommit removed)
- **Auto-detects GitHub repository** from git remote URL
- Interactive configuration wizard with npm-style UI
- Generates project-specific `.codedeploy/config` (git-committable)
- Auto-generates default appspec.yml and buildspec.yml based on project type
- Configures build-time and runtime environment variables
- Symlinks: `bin/aws-cd-setup.sh` and `bin/aws-code-setup.sh`

**info.sh** - Visual display of CodeDeploy configuration and status
- Shows application and deployment group details
- Displays recent deployment history with status
- Lists target instances with health indicators
- Color-coded status (success/warning/failure)
- Shows deployment timing and duration
- Can filter by project or show all deployments
- Symlinks: `bin/aws-cd-info.sh` and `bin/aws-code-info.sh`

**Note:** CodeDeploy agent is automatically installed on all instances via launch template user data. No manual agent installation required.

### CodeDeploy Configuration Management

**Project Configuration**: `.codedeploy/config`
- Stored in project root directory (git-committable)
- Contains application name, deployment group, S3 bucket, etc.
- Uses role NAMES instead of ARNs (looked up dynamically)
- Auto-creates `.gitignore` to exclude deployment artifacts
- Example structure:
  ```
  project-root/
  ├── .codedeploy/
  │   ├── config           # Main configuration (commit this)
  │   └── .gitignore       # Excludes artifacts
  ├── appspec.yml          # CodeDeploy app specification
  ├── buildspec.yml        # CodeBuild build instructions
  └── scripts/             # Deployment lifecycle hooks
      ├── before_install.sh
      ├── after_install.sh
      ├── start_server.sh
      ├── stop_server.sh
      └── fetch_env.sh     # Fetches runtime env vars from SSM
  ```

**Regional/AWS Config**: Reuses `aws-config.env`
- PROJECT_NAME, ENVIRONMENT, AWS_REGION
- Shared across all AWS automation scripts

### CodeDeploy Workflow

```bash
# 1. One-time unified setup (creates complete CI/CD pipeline)
cd /path/to/your/project
aws-cd-setup.sh  # or aws-code-setup.sh
# → Interactive wizard with validation
# → Checks for existing AWS resources
# → Auto-detects GitHub repository from git remote
# → Creates CodeDeploy application + deployment group
# → Creates CodePipeline + CodeBuild project
# → Generates .codedeploy/config (commit this!)
# → Generates default appspec.yml, buildspec.yml, and lifecycle scripts
# → Creates IAM roles and policies
# → Creates launch template with CodeDeploy agent pre-installed
# → Configures build and runtime environment variables

# 2. Commit and push to trigger deployment
git add .codedeploy/ buildspec.yml appspec.yml scripts/
git commit -m "Add CI/CD configuration"
git push
# → Pipeline automatically triggers on push
# → CodeBuild builds your application
# → CodeDeploy deploys to your instances

# 3. View deployment status and history
aws-cd-info.sh  # or aws-code-info.sh
# → Shows application details
# → Recent deployment history
# → Target instance health
# → Deployment timing

# 4. Update configuration (re-run setup anytime)
aws-cd-setup.sh
# → Validates existing resources
# → Shows current vs. desired configuration
# → Offers to keep, update, or recreate resources
# → Safe to re-run without destroying existing infrastructure
```

### Key Features

**Comprehensive Resource Validation**
- Queries existing AWS resources before any operations
- Visual configuration comparison (current vs. desired)
- Intelligent options: Keep / Update / Delete & Recreate
- Prevents duplicate resource creation
- Detects configuration drift automatically
- Safe to re-run setup without breaking existing infrastructure
- Supports:
  - CodeDeploy applications and deployment groups
  - CodeBuild projects (supports in-place updates)
  - CodePipeline pipelines
  - IAM roles with trust policy validation
  - S3 buckets for deployment artifacts

**Smart Project Detection**
- Scripts search upward for `.codedeploy/config`
- Can be run from any subdirectory of the project
- Auto-detects project type (Node.js, Python, Java, Go, etc.)
- Auto-detects GitHub repository from git remote
- Generates appropriate lifecycle scripts and buildspec.yml templates

**Git-Friendly Configuration**
- `.codedeploy/config` is designed to be committed
- Stores role NAMES, not ARNs (more portable)
- ARNs are resolved dynamically at runtime
- No secrets or credentials in config file

**Visual Feedback**
- Rich, color-coded terminal output (npm-style UI)
- Real-time deployment progress
- Health indicators (● green/yellow/red)
- Box-style UI for readability
- Configuration diff display (yellow=current, green=desired)

**Safe Operations**
- Validates appspec.yml and buildspec.yml before deployment
- Confirms destructive operations
- Automatic rollback on failure (configurable)
- Shows deployment errors with context
- GitHub-only source (simplified from multiple options)
